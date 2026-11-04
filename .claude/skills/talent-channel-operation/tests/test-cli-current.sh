#!/usr/bin/env bash
# Regresiones de compositor, turnos locales y brief de instancia. Solo en el arnés.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$TEST_DIR/../scripts"
if [ ! -f "$SC/repo-identity.conf" ] && [ -z "${TCO_REPO_DIR:-}" ]; then
  export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
  export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
  export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
  export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
fi
# shellcheck source=/dev/null
. "$SC/dispatch.sh"
FX="$TEST_DIR/fixtures/cli-current"
TMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST"' EXIT
export TCO_MODELOS_REGISTRO="$TEST_DIR/fixtures/modelos-cli-current.conf"
MODEL_OPUS="$(tco_modelo_read plan)" || exit 1
MODEL_SONNET="$(tco_modelo_read coding)" || exit 1
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: esperaba [%s], obtuvo [%s]\n' "$1" "$3" "$2"; fi
}
relay='lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt — es tu brief de tarea; síguelo y presenta el plan con ExitPlanMode'
ok 'capturas neutralizadas sin secretos ni cuentas' "$(cat "$FX"/*.txt | tco_fixture_secret_scan; echo $?)" 0
for wrap in two three; do
  cap="$(cat "$FX/wrapped-$wrap.txt")"
  ok "eco íntegro en $wrap líneas" "$(printf '%s' "$cap" | tco_tui_regions_from composer | tco_composer_echo_from "$relay"; echo $?)" 0
  ok "pendiente en $wrap líneas" "$(printf '%s' "$cap" | tco_input_pending_from "$relay"; echo $?)" 0
  ok "pendiente no acredita entrega en $wrap líneas" "$(tco_delivered_from "$cap" "$relay"; echo $?)" 1
  incomplete="${cap/plan con ExitPlanMode/plan con}"
  ok "parte ausente en $wrap líneas" "$(printf '%s' "$incomplete" | tco_tui_regions_from composer | tco_composer_echo_from "$relay"; echo $?)" 1
done
cap="$(cat "$FX/triplicated.txt")"
ok 'triplicado parcial bloquea eco íntegro' "$(printf '%s' "$cap" | tco_tui_regions_from composer | tco_composer_echo_from "$relay"; echo $?)" 1
ok 'triplicado es pendiente ambiguo' "$(printf '%s' "$cap" | tco_input_pending_from 'lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt'; echo $?)" 2
ok 'duplicado íntegro es ambiguo' "$(printf '%s\n%s' "$relay" "$relay" | tco_unique_token_in_region_from "$relay"; echo $?)" 2
ok 'relay parcial no autoriza re-submit por prefijo' "$(sed 's/plan con ExitPlanMode/plan con/' "$FX/wrapped-two.txt" | tco_input_pending_from 'lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt' "$relay"; echo $?)" 2
ok 'relay íntegro autoriza re-submit sin re-tipear' "$(tco_input_pending_from 'lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt' "$relay" < "$FX/wrapped-two.txt"; echo $?)" 0
ok 'espacios solos no son token' "$(printf 'texto' | tco_token_in_region_from '  '; echo $?)" 1
ok 'eco dim no acredita envío' "$(printf '\033[2m%s\033[0m' "$relay" | tco_composer_echo_from "$relay"; echo $?)" 1
ok 'entrega reconoce texto partido en transcript' "$(tco_delivered_from "$(printf '%s\n' 'lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt — es tu brief de' 'tarea; síguelo y presenta el plan con ExitPlanMode'; cat "$FX/plan.txt")" "$relay"; echo $?)" 0

# Mocks registran el submit: un eco negativo debe dejar cero Enters.
_send_test() (
  local capture="$1"
  tco_pane_busy() { return 1; }
  incus() { printf '%s\n' "$*" >> "$TMP_TEST/send.calls"; }
  sleep() { :; }
  tco_cap_pane_e() {
    if grep -q ' -l --' "$TMP_TEST/send.calls"; then cat "$capture"; else cat "$TEST_DIR/fixtures/pane/claude_2.1.289/idle.txt"; fi
  }
  tco_cap_pane() { cat "$capture"; }
  : > "$TMP_TEST/send.calls"
  _tco_send_text_submit 01 v:.0 "$relay" C-m yes >/dev/null 2>&1
  local rc=$?
  printf '%s:%s' "$rc" "$(grep -c 'C-m' "$TMP_TEST/send.calls")"
)
ok 'envío real separado con eco partido' "$(_send_test "$FX/wrapped-two.txt")" '0:1'
ok 'envío bloqueado sin parte del texto' "$(sed 's/plan con ExitPlanMode/plan con/' "$FX/wrapped-two.txt" > "$TMP_TEST/incomplete.txt"; _send_test "$TMP_TEST/incomplete.txt")" '2:0'
ok 'envío bloqueado con compositor triplicado' "$(_send_test "$FX/triplicated.txt")" '2:0'

for tag in local-command-stdout local-command-stderr local-command-caveat command-name command-message; do
  local_rec="$(jq -cn --arg tag "$tag" '{type:"user",uuid:"local",message:{content:("<"+$tag+">token</"+$tag+">")}}')"
  printf '%s\n' "$local_rec" > "$TMP_TEST/$tag.jsonl"
  ok "orden $tag no está en vuelo" "$(tco_transcript_inflight_from < "$TMP_TEST/$tag.jsonl"; echo $?)" 1
  ok "orden $tag no tiene uuid de submisión" "$(tco_user_submit_uuids_from token < "$TMP_TEST/$tag.jsonl")" ''
  ok "orden $tag no tiene uuid posterior" "$(tco_user_submit_after_from token 2000-01-01T00:00:00Z < "$TMP_TEST/$tag.jsonl"; echo $?)" 1
  ok "orden $tag no invalida plan" "$(printf '%s\n%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan","name":"ExitPlanMode","input":{"plan":"Plan vigente"}}]}}' "$local_rec" | tco_exitplan_plan_from)" 'Plan vigente'
  ok "orden $tag no borra texto del asistente" "$(printf '%s\n%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Respuesta"}]}}' "$local_rec" | tco_last_assistant_text_from)" 'Respuesta'
  ok "orden $tag no oculta humano sin respuesta" "$(printf '%s\n%s\n' '{"type":"user","message":{"content":"humano"}}' "$local_rec" | tco_transcript_inflight_from; echo $?)" 0
done
human='{"type":"user","uuid":"human","message":{"content":"token"}}'
ok 'humano está en vuelo' "$(printf '%s' "$human" | tco_transcript_inflight_from; echo $?)" 0
ok 'humano acredita uuid' "$(printf '%s' "$human" | tco_user_submit_uuids_from token)" human
ok 'humano invalida plan anterior' "$(printf '%s\n%s' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan","name":"ExitPlanMode","input":{"plan":"Plan"}}]}}' "$human" | tco_exitplan_plan_from; echo $?)" 4
ok 'texto local en array no es turno' "$(printf '%s' '{"type":"user","message":{"content":[{"type":"text","text":"<command-message>token"}]}}' | tco_transcript_inflight_from; echo $?)" 1
ok 'humano en array está en vuelo' "$(printf '%s' '{"type":"user","message":{"content":[{"type":"text","text":"humano"}]}}' | tco_transcript_inflight_from; echo $?)" 0
# 1.7.4f: el marcador de interrupción final es reposo; un humano sin respuesta sigue en vuelo.
ok 'JSONL real del CLI: interrupción final (ch11) no está en vuelo' "$(tco_transcript_inflight_from < "$FX/transcript-interrumpido-ch11.jsonl"; echo $?)" 1
ok 'JSONL real del CLI: prompt humano como string sin respuesta está en vuelo' "$(tco_transcript_inflight_from < "$FX/transcript-humano-cadena.jsonl"; echo $?)" 0
ok 'interrupción tras turno de asistente no está en vuelo' "$( { printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"plan"}]}}'; cat "$FX/transcript-interrumpido-ch11.jsonl"; } | tco_transcript_inflight_from; echo $?)" 1
ok 'interrupción como STRING es un humano que la teclea: está en vuelo' "$(printf '%s' '{"type":"user","message":{"content":"[Request interrupted by user]"}}' | tco_transcript_inflight_from; echo $?)" 0
ok 'interrupción por herramienta no está en vuelo' "$(printf '%s' '{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}' | tco_transcript_inflight_from; echo $?)" 1
ok 'humano tras la interrupción está en vuelo' "$( { cat "$FX/transcript-interrumpido-ch11.jsonl"; cat "$FX/transcript-humano-cadena.jsonl"; } | tco_transcript_inflight_from; echo $?)" 0
ok 'humano que añade texto al marcador está en vuelo' "$(printf '%s' '{"type":"user","message":{"content":"[Request interrupted by user] sigue"}}' | tco_transcript_inflight_from; echo $?)" 0
ok 'humano con corchetes no es marcador' "$(printf '%s' '{"type":"user","message":{"content":"[nota del humano]"}}' | tco_transcript_inflight_from; echo $?)" 0
ok 'humano que menciona interrupted no es marcador' "$(printf '%s' '{"type":"user","message":{"content":[{"type":"text","text":"why was it interrupted"}]}}' | tco_transcript_inflight_from; echo $?)" 0
ok 'marcador más texto humano en array está en vuelo' "$(printf '%s' '{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"},{"type":"text","text":"humano"}]}}' | tco_transcript_inflight_from; echo $?)" 0
# --- 1.7.4f ronda 2: las 4 funciones usan el ÚNICO predicado compartido del marcador de interrupción ---
FXI="$FX/transcript-interrumpido-ch11.jsonl"; FXH="$FX/transcript-humano-cadena.jsonl"
plan_rec='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan","name":"ExitPlanMode","input":{"plan":"Plan vigente"}}]}}'
asst_rec='{"type":"assistant","message":{"content":[{"type":"text","text":"Respuesta"}]}}'
# El marcador REAL de ch11 (array de un `text`) y el MISMO texto como STRING (un humano que lo teclea).
# tco_user_submit_* solo mira content STRING: un array nunca es submisión (con o sin predicado); el
# marcador real es siempre array, así que el string con su texto es una submisión humana.
int_arr="$(jq -c 'select(.type=="user") | .uuid="u-int"' "$FXI")"
int_str="$(jq -c 'select(.type=="user") | .uuid="u-int" | .message.content = .message.content[0].text' "$FXI")"
hum_uuid="$(jq -c 'select(.type=="user") | .uuid="u-hum"' "$FXH")"
# tco_exitplan_plan_from: el caso clave del plan-gate (plan vigente + Escape) sigue devolviendo el plan.
ok 'exitplan: plan vigente + Escape real de ch11 devuelve el plan' "$( { printf '%s\n' "$plan_rec"; cat "$FXI"; } | tco_exitplan_plan_from; echo "rc=$?")" $'Plan vigente\nrc=0'
ok 'exitplan: plan vigente + humano real sigue obsoleto (rc 4)' "$( { printf '%s\n' "$plan_rec"; cat "$FXH"; } | tco_exitplan_plan_from >/dev/null; echo $?)" 4
ok 'exitplan: humano tras el Escape deja el plan obsoleto (rc 4)' "$( { printf '%s\n' "$plan_rec"; cat "$FXI" "$FXH"; } | tco_exitplan_plan_from >/dev/null; echo $?)" 4
ok 'exitplan: humano con el marcador más texto sigue obsoleto (rc 4)' "$( { printf '%s\n' "$plan_rec"; printf '%s\n' '{"type":"user","message":{"content":"[Request interrupted by user] sigue"}}'; } | tco_exitplan_plan_from >/dev/null; echo $?)" 4
# tco_last_assistant_text_from: el Escape no abre un turno nuevo.
ok 'texto del asistente: el Escape real de ch11 no corta el último turno' "$( { cat "$FXH"; printf '%s\n' "$asst_rec"; cat "$FXI"; } | tco_last_assistant_text_from; echo "rc=$?")" $'Respuesta\nrc=0'
ok 'texto del asistente: humano real posterior sigue cortando (rc 1)' "$( { printf '%s\n' "$asst_rec"; cat "$FXH"; } | tco_last_assistant_text_from >/dev/null; echo $?)" 1
ok 'texto del asistente: marcador más texto humano sigue cortando (rc 1)' "$( { printf '%s\n' "$asst_rec"; printf '%s\n' '{"type":"user","message":{"content":"[Request interrupted by user] sigue"}}'; } | tco_last_assistant_text_from >/dev/null; echo $?)" 1
# tco_user_submit_*: el marcador no es una submisión humana.
ok 'submit uuids: el marcador real de ch11 (array) no es submisión' "$(printf '%s\n' "$int_arr" | tco_user_submit_uuids_from interrupted; echo "rc=$?")" $'rc=0'
ok 'submit after: el marcador real de ch11 (array) no es submisión' "$(printf '%s\n' "$int_arr" | tco_user_submit_after_from interrupted 2000-01-01T00:00:00Z; echo $?)" 1
ok 'submit uuids: el texto del marcador como STRING es una submisión humana' "$(printf '%s\n' "$int_str" | tco_user_submit_uuids_from interrupted)" u-int
ok 'submit after: el texto del marcador como STRING es una submisión humana' "$(printf '%s\n' "$int_str" | tco_user_submit_after_from interrupted 2000-01-01T00:00:00Z)" u-int
ok 'submit uuids: el prompt humano real sí es submisión' "$(printf '%s\n' "$hum_uuid" | tco_user_submit_uuids_from humano)" u-hum
ok 'submit after: el prompt humano real sí es submisión' "$(printf '%s\n' "$hum_uuid" | tco_user_submit_after_from humano 2000-01-01T00:00:00Z)" u-hum
ok 'submit uuids: marcador más texto humano sí es submisión' "$(printf '%s\n' '{"type":"user","uuid":"u-mix","message":{"content":"[Request interrupted by user] sigue"}}' | tco_user_submit_uuids_from interrupted)" u-mix
# El predicado puro compartido (uso desde shell).
for c in '[{"type":"text","text":"[Request interrupted by user]"}]' '[{"type":"text","text":"[Request interrupted by user for tool use]"}]'; do
  ok "predicado: es solo el marcador: $c" "$(printf '%s' "$c" | tco_interrupt_marker_content; echo $?)" 0
done
for c in '"[Request interrupted by user]"' '"[Request interrupted by user for tool use]"' '"  [Request interrupted by user]\n"' '"[Request interrupted by user] sigue"' '"[nota]"' '"interrupted"' '""' \
  '[]' '["hola"]' '["[Request interrupted by user]"]' '[1]' '[true]' '[[]]' '[null]' '[[{"type":"text","text":"[Request interrupted by user]"}]]' \
  '[{"type":"text","text":"[Request interrupted by user]"},{"type":"text","text":"[Request interrupted by user]"}]' \
  '[{"type":"text","text":"[Request interrupted by user]"},{"type":"text","text":"hola"}]' \
  '[{"type":"text","text":"[Request interrupted by user]"},{"type":"image"}]' \
  '[{"type":"image"}]' '[{"type":"tool_result","text":"[Request interrupted by user]"}]' '[{"text":"[Request interrupted by user]"}]' \
  '[{"type":"text","text":5}]' '[{"type":"text"}]' '[{"type":"text","text":" [Request interrupted by user]"}]' \
  '[{"type":"text","text":"[Request interrupted by user]\n"}]' '[{"type":"text","text":"[request interrupted by user]"}]' \
  '{"type":"text","text":"[Request interrupted by user]"}' '5' 'null'; do
  ok "predicado: NO es solo el marcador: $c" "$(printf '%s' "$c" | tco_interrupt_marker_content; echo $?)" 1
done
# Anti-divergencia (estática): cada función llama al predicado compartido y NO lleva el literal; el
# literal vive en UNA sola línea de código de lib.sh.
for fn in tco_transcript_inflight_from tco_exitplan_plan_from tco_last_assistant_text_from tco_user_submit_after_from tco_user_submit_uuids_from; do
  body="$(declare -f "$fn")"
  ok "anti-divergencia: $fn llama a interrupt_only" "$(case "$body" in *'|interrupt_only'*) echo si ;; *) echo no ;; esac)" si
  ok "anti-divergencia: $fn antepone el predicado compartido" "$(case "$body" in *'$_TCO_JQ_INTERRUPT_DEFS'*) echo si ;; *) echo no ;; esac)" si
  ok "anti-divergencia: $fn no lleva el literal del marcador" "$(case "$body" in *'Request interrupted'*) echo si ;; *) echo no ;; esac)" no
done
ok 'anti-divergencia: el literal del marcador está en UNA sola línea de código de lib.sh' "$(grep -v '^[[:space:]]*#' "$SC/lib.sh" | grep -c 'Request interrupted by user')" 1
# Anti-divergencia (de comportamiento): cambiar SOLO el predicado cambia las 4 funciones.
(
  _TCO_JQ_INTERRUPT_DEFS='def interrupt_only: type=="string" and . == "[MARCA-X]";'
  mx='{"type":"user","uuid":"u-x","timestamp":"2026-10-20T00:00:00Z","message":{"content":"[MARCA-X]"}}'
  ok 'predicado cambiado: inflight trata MARCA-X como reposo' "$(printf '%s\n' "$mx" | tco_transcript_inflight_from; echo $?)" 1
  ok 'predicado cambiado: inflight ya no trata el marcador real como reposo' "$(tco_transcript_inflight_from < "$FXI"; echo $?)" 0
  ok 'predicado cambiado: exitplan conserva el plan tras MARCA-X' "$( { printf '%s\n' "$plan_rec" "$mx"; } | tco_exitplan_plan_from; echo "rc=$?")" $'Plan vigente\nrc=0'
  ok 'predicado cambiado: exitplan queda obsoleto tras el marcador real' "$( { printf '%s\n' "$plan_rec"; cat "$FXI"; } | tco_exitplan_plan_from >/dev/null; echo $?)" 4
  ok 'predicado cambiado: texto del asistente atraviesa MARCA-X' "$( { cat "$FXH"; printf '%s\n' "$asst_rec" "$mx"; } | tco_last_assistant_text_from; echo "rc=$?")" $'Respuesta\nrc=0'
  ok 'predicado cambiado: texto del asistente corta en el marcador real' "$( { cat "$FXH"; printf '%s\n' "$asst_rec"; cat "$FXI"; } | tco_last_assistant_text_from >/dev/null; echo $?)" 1
  ok 'predicado cambiado: submit uuids ignora MARCA-X' "$(printf '%s\n' "$mx" | tco_user_submit_uuids_from MARCA)" ''
  ok 'predicado cambiado: submit after ignora MARCA-X' "$(printf '%s\n' "$mx" | tco_user_submit_after_from MARCA 2000-01-01T00:00:00Z; echo $?)" 1
  ok 'predicado cambiado: submit uuids cuenta el marcador real como submisión' "$(printf '%s\n' "$int_str" | tco_user_submit_uuids_from interrupted)" u-int
  ok 'predicado cambiado: submit after cuenta el marcador real como submisión' "$(printf '%s\n' "$int_str" | tco_user_submit_after_from interrupted 2000-01-01T00:00:00Z)" u-int
  # el subshell no puede incrementar los contadores del padre: los reenvía
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP_TEST/sub.counts"
)
read -r PASS FAIL < "$TMP_TEST/sub.counts"
# Anti-divergencia por FORMA (1.7.4f ronda 3): las DOS variantes del marcador en forma array y en forma
# STRING, en las 4 funciones (5 sondas), con el predicado real y con el predicado sustituido por
# «siempre falso» y «siempre cierto». Resultado H = tratado como humano · M = reposo / no es humano.
# Un criterio privado que una función añada por su cuenta (aunque siga llamando al predicado) rompe
# la igualdad con lo que dicta SOLO el predicado.
_probe() { # sonda registro -> H|M
  local rc
  case "$1" in
    inflight) if printf '%s\n' "$2" | tco_transcript_inflight_from; then echo H; else echo M; fi ;;
    exitplan) { printf '%s\n' "$plan_rec" "$2"; } | tco_exitplan_plan_from >/dev/null; rc=$?; if [ "$rc" -eq 4 ]; then echo H; else echo M; fi ;;
    lasttext) if { cat "$FXH"; printf '%s\n' "$asst_rec" "$2"; } | tco_last_assistant_text_from >/dev/null; then echo M; else echo H; fi ;;
    uuids) if [ -n "$(printf '%s\n' "$2" | tco_user_submit_uuids_from interrupted)" ]; then echo H; else echo M; fi ;;
    after) if printf '%s\n' "$2" | tco_user_submit_after_from interrupted 2000-01-01T00:00:00Z >/dev/null; then echo H; else echo M; fi ;;
  esac
}
_exp() { # predicado forma sonda -> H|M esperado (solo lo dicta el predicado; submit nunca mira arrays)
  case "$1:$2:$3" in
    true:*) echo M ;;
    *:arr:uuids|*:arr:after) echo M ;;
    real:arr:*) echo M ;;
    *) echo H ;;
  esac
}
V1='[Request interrupted by user]'; V2='[Request interrupted by user for tool use]'
for pred in real false true; do
  case "$pred" in
    real) defs="$_TCO_JQ_INTERRUPT_DEFS" ;;
    false) defs='def interrupt_only: false;' ;;
    true) defs='def interrupt_only: true;' ;;
  esac
  for var in v1 v2; do
    txt="$V1"; [ "$var" = v2 ] && txt="$V2"
    rec_arr="$(jq -cn --arg t "$txt" '{type:"user",uuid:"u-f",timestamp:"2026-10-20T00:00:00Z",message:{content:[{type:"text",text:$t}]}}')"
    rec_str="$(jq -cn --arg t "$txt" '{type:"user",uuid:"u-f",timestamp:"2026-10-20T00:00:00Z",message:{content:$t}}')"
    for form in arr str; do
      rec="$rec_arr"; [ "$form" = str ] && rec="$rec_str"
      for probe in inflight exitplan lasttext uuids after; do
        ok "forma: predicado $pred, $var en $form, $probe" "$( _TCO_JQ_INTERRUPT_DEFS="$defs"; _probe "$probe" "$rec")" "$(_exp "$pred" "$form" "$probe")"
      done
    done
  done
done
# Coste lineal (ninguna función recorta ni hace regex sobre el texto): un humano con 100000 espacios
# seguidos termina en < 1 s en cada sonda (medido con date +%s%N, declarado en la entrega).
sp_str="$(jq -nc '{type:"user",uuid:"u-sp",timestamp:"2026-10-20T00:00:00Z",message:{content:("interrupted"+([range(100000)|" "]|join(""))+"y")}}')"
sp_arr="$(jq -nc '{type:"user",uuid:"u-sp",timestamp:"2026-10-20T00:00:00Z",message:{content:[{type:"text",text:("[Request interrupted"+([range(100000)|" "]|join(""))+"by user]")}]}}')"
for probe in inflight exitplan lasttext uuids after; do
  for form in str arr; do
    rec="$sp_str"; [ "$form" = arr ] && rec="$sp_arr"
    t0="$(date +%s%N)"; got="$(_probe "$probe" "$rec")"; t1="$(date +%s%N)"
    ms=$(( (t1 - t0) / 1000000 ))
    printf 'INFO 100000 espacios en %s (%s): %s ms\n' "$form" "$probe" "$ms"
    want=H; { [ "$probe" = uuids ] || [ "$probe" = after ]; } && [ "$form" = arr ] && want=M
    ok "100000 espacios en $form ($probe): clasificado" "$got" "$want"
    ok "100000 espacios en $form ($probe): termina en menos de 1 s" "$([ "$ms" -lt 1000 ] && echo si || echo "no:${ms}ms")" si
  done
done
ok 'JSON corrupto no acredita uuid' "$(printf '%s' '{invalido' | tco_user_submit_uuids_from token; echo $?)" 1
meta_result='{"type":"user","isMeta":true,"message":{"content":[{"type":"tool_result","tool_use_id":"plan","content":"ok"}]}}'
ok 'resultado meta cierra herramienta pendiente' "$(printf '%s\n%s' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan"}]}}' "$meta_result" | tco_transcript_inflight_from; echo $?)" 1
ok 'resultado meta acredita aprobación del plan' "$(printf '%s\n%s' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan","name":"ExitPlanMode","input":{"plan":"Plan"}}]}}' "$meta_result" | tco_exitplan_plan_from; echo $?)" 3

for state in idle busy plan; do
  expected=1
  [ "$state" = busy ] && expected=0
  ok "captura real $state" "$(tco_pane_busy_from < "$FX/$state.txt"; echo $?)" "$expected"
done
for modal in 'How is Claude doing this session? (optional)' 'How would you rate this session?' 'Can Anthropic look at your session transcript?' 'Yes, I trust this folder' 'Select model' 'Bypass Permissions mode'; do
  case "$modal" in How*) expected=survey-rating ;; Can*) expected=survey ;; Yes*) expected=trust ;; *) expected=modal ;; esac
  ok "modal conocido: $modal" "$(printf '%s' "$modal" | tco_pane_anomaly)" "$expected"
  ok "frase histórica con compositor identificable: $modal" "$( { printf '%s\n' "$modal"; cat "$FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 1
done
ok 'redibujado incompleto es desconocido' "$(printf '───\n❯ texto\n' | tco_pane_busy_from; echo $?)" 2
ok 'separadores de prosa sin prompt no son compositor' "$(printf '───\ntexto\n───\nshift+tab\n' | tco_pane_busy_from; echo $?)" 2
ok 'prosa que cita actividad no está ocupada' "$( { printf '%s\n' 'El informe cita esc to interrupt'; cat "$FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 1
ok 'encuesta reconocida' "$(printf 'How would you rate this session?' | tco_pane_anomaly)" survey-rating
ok 'encuesta real del ensayo nunca idle' "$(tco_pane_busy_from < "$FX/survey-rating.txt"; echo $?)" 2
ok 'encuesta descartada con cero' "$(
  incus() { printf '%s\n' "$*" > "$TMP_TEST/heal.calls"; }; sleep() { :; }
  tco_cap_pane() { cat "$FX/survey-rating.txt"; }
  tco_pane_heal 01 v:.0 survey-rating >/dev/null
  grep -c 'v:.0.* 0' "$TMP_TEST/heal.calls"
)" 1
ok 'idle persistido con encuesta sigue bloqueado' "$(
  _tco_carril_session() { printf 'sid idle 1'; }
  _tco_transcript_lines() { printf '%s' '{"type":"user","message":{"content":"<local-command-stdout>done"}}'; }
  tco_cap_pane() { printf 'How would you rate this session?'; }
  tco_pane_busy 01 v:.0; echo $?
)" 2
picker="$(printf '%s\n' 'Select model' '  1. Sonnet 5.5' '❯ 2. Opus 5.5 ✔' 'Kept model as Opus 5.5')"
ok 'picker reconoce modelo activo con respuesta local' "$(printf '%s' "$picker" | tco_model_is "$MODEL_OPUS"; echo $?)" 0
ok 'picker selecciona opción actual por número' "$(printf '%s' "$picker" | tco_model_picker_pick "$MODEL_OPUS")" 2
ok 'respuesta local sola no confirma modelo' "$(printf 'Kept model as Opus 5.5' | tco_model_is "$MODEL_OPUS"; echo $?)" 1

cat > "$TMP_TEST/docs.conf" <<'EOF'
TF_GATE_IDS="docs"
TF_GATE_CMD_docs="bash scripts/docs.sh"
EOF
cat > "$TMP_TEST/multi.conf" <<'EOF'
TF_GATE_IDS="docs db-guards"
TF_GATE_CMD_docs="bash scripts/docs.sh"
TF_GATE_CMD_db_guards="bash scripts/db.sh"
EOF
template="$SC/../assets/prompt-dispatch.tmpl"
brief="$(TCO_TF_MANIFEST="$TMP_TEST/docs.conf" TCO_REPO_STACK=ninguno tco_dispatch_instance_blocks "$template")"
ok 'brief solo gate docs' "$(printf '%s' "$brief" | grep -c 'docs: bash scripts/docs.sh')" 1
ok 'brief sin rutas ni gates ajenos' "$(printf '%s' "$brief" | grep -cE 'npm run|supabase/migrations|migration_slots|typecheck/lint/build')" 0
brief="$(TCO_TF_MANIFEST="$TMP_TEST/multi.conf" TCO_REPO_STACK=supabase tco_dispatch_instance_blocks "$template")"
ok 'brief incluye todos los gates' "$(printf '%s' "$brief" | grep -cE 'docs: bash scripts/docs.sh|db-guards: bash scripts/db.sh')" 2
ok 'brief con stack de migraciones' "$(printf '%s' "$brief" | grep -c 'MIGRACIONES:')" 1
ok 'brief sin manifiesto falla cerrado' "$(TCO_TF_MANIFEST="$TMP_TEST/absent.conf" TCO_REPO_STACK=ninguno tco_dispatch_instance_blocks "$template"; echo $?)" 1
printf 'TF_GATE_IDS="missing"\n' > "$TMP_TEST/missing.conf"
ok 'gate sin comando falla cerrado' "$(tco_dispatch_gate_lines "$TMP_TEST/missing.conf"; echo $?)" 1
printf 'TF_GATE_IDS="docs docs"\nTF_GATE_CMD_docs="true"\n' > "$TMP_TEST/duplicate.conf"
ok 'gates repetidos fallan cerrado' "$(tco_dispatch_gate_lines "$TMP_TEST/duplicate.conf" >/dev/null; echo $?)" 1
ok 'stack desconocido falla cerrado' "$(TCO_TF_MANIFEST="$TMP_TEST/docs.conf" TCO_REPO_STACK=otro tco_dispatch_instance_blocks "$template"; echo $?)" 1
ok 'canales arrancan sin encuestas en ambos paneles' "$(grep -c 'send-keys.*CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1' "$SC/../../talent-channels/assets/launcher-v.tmpl")" 2
# Los dos panes lanzan la orden acreditada por la sonda (tco_orden_acreditada), que lleva el prefijo sin encuestas.
ok 'despacho arranca sin encuestas en ambos paneles' "$(grep -c "respawn-pane -k -t '\$P_[A-Z]*' -c '\$rp' '\$LANZ_[A-Z]*'" "$SC/dispatch.sh")/$(grep -c 'LANZ_[A-Z]*="\$(tco_orden_acreditada ' "$SC/dispatch.sh")/$(
  _TCO_ACREDITADO['%9']='claude|/x/claude|1:2'; _TCO_LANZADOR['%9']=/x/claude-root
  tco_orden_acreditada TCO_DEV_CLI %9 '' | grep -c '^CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 ')" 2/2/1
ok 'torre arranca sin encuestas' "$(grep -c 'CMD=.*CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1' "$SC/../../talent-orchestrator/scripts/torre-resume.sh")" 1

REAL_FX="$TEST_DIR/fixtures/pane/claude_2.1.289"
ok 'busy conserva exactamente la captura con contador' "$(cmp -s "$REAL_FX/busy.txt" "$REAL_FX/t-5.txt"; echo $?)" 0
for state in idle busy modal redraw done t-1 t-3 t-5; do
  case "$state" in idle|done) expected=1 ;; modal|redraw) expected=2 ;; *) expected=0 ;; esac
  ok "captura de versión actual $state" "$(tco_pane_busy_from < "$REAL_FX/$state.txt"; echo $?)" "$expected"
  ok "captura de versión actual publicable $state" "$(tco_fixture_secret_scan < "$REAL_FX/$state.txt"; echo $?)" 0
done
ok 'actividad citada antes de otra línea es reposo' "$( { printf '✽ Schlepping…\nRespuesta terminada\n'; cat "$REAL_FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 1
ok 'turno terminado es reposo' "$(tco_pane_busy_from < "$REAL_FX/done.txt"; echo $?)" 1
ok 'actividad citada cerca del compositor no ocupa' "$( { printf '✻ Schlepping… (3s · ↓ 98 tokens)\nRespuesta terminada\n\n'; sed -n '/^───/,$p' "$REAL_FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 1
for activity in '✶ Schlepping…' '· Schlepping… (3s · ↓ 74 tokens)' '✻ Schlepping… (3s · ↓ 98 tokens · thinking with high effort)'; do
  ok "actividad pegada al compositor $activity" "$( { printf '%s\n\n' "$activity"; sed -n '/^───/,$p' "$REAL_FX/idle.txt"; } | tco_pane_busy_from; echo $?)" 0
done

_activity_capture() {
  printf '%s\n' "$1"
  sed -n '/^───/,$p' "$REAL_FX/idle.txt"
}
ok 'actividad con consejo debajo sigue ocupada' "$( _activity_capture $'✢ Onioning… (32s · ↓ 2.9k tokens)\n  ⎿  Tip: consejo\n     continuación' | tco_pane_busy_from; echo $?)" 0
ok 'actividad con tareas anexas sigue ocupada' "$( _activity_capture $'✶ Schlepping…\n  ⎿  ☐ Primera tarea\n     ☐ Segunda tarea\n     ☑ Tercera tarea' | tco_pane_busy_from; echo $?)" 0
ok 'actividad citada sangrada deja el panel en reposo' "$( _activity_capture $'Respuesta terminada\n  ✻ Schlepping… (3s · ↓ 98 tokens)' | tco_pane_busy_from; echo $?)" 1
ok 'turno terminado con shell pendiente está en reposo' "$( _activity_capture '✻ Baked for 7s · done 7:33 PM · 1 shell still running' | tco_pane_busy_from; echo $?)" 1
ok 'línea posterior en columna cero decide reposo' "$( _activity_capture $'✶ Schlepping…\n  ⎿  Tip: consejo\nRespuesta terminada' | tco_pane_busy_from; echo $?)" 1

ok 'redraw sin compositor falla' "$(printf 'solo transcript\n' | tco_redraw_fixture_from >/dev/null; echo $?)" 1
ok 'redraw con transcript vacío falla' "$(sed -n '/^───/,$p' "$REAL_FX/idle.txt" | tco_redraw_fixture_from >/dev/null; echo $?)" 1
ok 'redraw derivado es desconocido' "$(tco_redraw_fixture_from < "$REAL_FX/busy.txt" | tco_pane_busy_from; echo $?)" 2
ok 'redraw coincide con recorte versionado' "$(tco_redraw_fixture_from < "$REAL_FX/busy.txt")" "$(cat "$REAL_FX/redraw.txt")"
rc=0
TCO_FIXTURE_DIR="$TMP_TEST/redraw-fixture" bash "$SC/capture-pane-fixtures.sh" --from-stdin --cli-version claude:2.1.289 redraw < "$REAL_FX/busy.txt" >/dev/null 2>&1 || rc=$?
ok 'capturador deriva redraw con el mismo método' "$rc:$(cat "$TMP_TEST/redraw-fixture/claude_2.1.289/redraw.txt")" "0:$(cat "$REAL_FX/redraw.txt")"
rc=0
printf 'sin compositor\n' | TCO_FIXTURE_DIR="$TMP_TEST/rejected-redraw" bash "$SC/capture-pane-fixtures.sh" --from-stdin --cli-version claude:2.1.289 redraw >/dev/null 2>&1 || rc=$?
ok 'capturador rechaza redraw sin compositor y no escribe' "$rc:$([ -e "$TMP_TEST/rejected-redraw/claude_2.1.289/redraw.txt" ] && echo escrito || echo ausente)" 1:ausente

for state in idle busy t-1 t-3 t-5; do
  ok "ancla real sin quitar relleno inferior $state" "$(tco_tui_anchor_from < "$REAL_FX/$state.txt" | grep -cE '^[0-9]+ [0-9]+$')" 1
  for region in transcript composer status; do
    ok "región real $state $region" "$(tco_tui_regions_from "$region" < "$REAL_FX/$state.txt" >/dev/null; echo $?)" 0
  done
done
for region in transcript composer status; do
  ok "modal sin región inventada $region" "$(tco_tui_regions_from "$region" < "$REAL_FX/modal.txt" >/dev/null; echo $?)" 2
done
audit_capture="$(printf 'STOP-AUDIT — ABC-1234 · informe pre-push\n──────\nInforme completo\n'; sed -n '/^───/,$p' "$REAL_FX/idle.txt")"
ok 'extractor conserva separador de prosa y excluye compositor recto' "$(printf '%s\n' "$audit_capture" | tco_extract_stop_audit | grep -cE '^❯|ctx:|bypass permissions')" 0
ok 'extractor conserva informe y separador' "$(printf '%s\n' "$audit_capture" | tco_extract_stop_audit | grep -cE '^──────$|^Informe completo$')" 2

_model_current_test() (
  local requested="$1" final="$2" rc=0
  # La familia y versión se derivan del registro; Default no es la fila Sonnet.
  sleep() { :; }
  tco_cap_pane_e() { cat "$REAL_FX/idle.txt"; }
  tco_pane_busy() { return 1; }
  tco_clear_input() { :; }
  # El transporte se prueba con capturas cambiantes en las regresiones de envío.
  _tco_send_text_submit() { :; }
  printf '0\n' > "$TMP_TEST/model-clock"
  : > "$TMP_TEST/model-calls"
  date() { local n; read -r n < "$TMP_TEST/model-clock"; n=$((n+1)); printf '%s\n' "$n" > "$TMP_TEST/model-clock"; printf '%s\n' "$n"; }
  tco_cap_pane() {
    if [ -e "$TMP_TEST/model-chosen" ]; then
      printf 'Kept model as %s\n' "$final"
      cat "$REAL_FX/idle.txt"
    else cat "$REAL_FX/modal.txt"; fi
  }
  incus() {
    printf '%s\n' "$*" >> "$TMP_TEST/model-calls"
    [[ "$*" != *"v:.0' 4"* ]] || : > "$TMP_TEST/model-chosen"
    return 0
  }
  rm -f "$TMP_TEST/model-chosen"
  tco_current_model_dialog() {
    case "$final" in
      Opus*) sed 's/Sonnet ✔/Sonnet/; s/4\. Opus /4. Opus ✔ /' "$REAL_FX/modal.txt" ;;
      *) cat "$REAL_FX/modal.txt" ;;
    esac
  }
  TCO_EFFORT_CONFIRM_MAX=2 tco_set_model 01 v:.0 "$requested" > "$TMP_TEST/model-result" 2>&1 || rc=$?
  printf '%s:%s:%s' "$rc" "$(grep -c 'ERROR:' "$TMP_TEST/model-result")" "$(grep -cE 'send-keys.* [0-9]+$' "$TMP_TEST/model-calls")"
)
ok 'modelo ya activo con captura real y Kept es éxito sin error' "$(_model_current_test "$MODEL_SONNET" 'Sonnet 5.5')" 0:0:0
ok 'Kept durante cambio confirmado es éxito sin error' "$(_model_current_test "$MODEL_OPUS" 'Opus 5.5')" 0:0:1
ok 'Kept con modelo activo distinto falla cerrado' "$(_model_current_test "$MODEL_OPUS" 'Sonnet 5.5')" 2:1:1

_delayed_echo_test() (
  local mode="$1" rc=0 delivery=- polls_seen
  tco_pane_busy() { return 1; }
  incus() { printf '%s\n' "$*" >> "$TMP_TEST/delayed.calls"; }
  sleep() { :; }
  tco_cap_pane_e() {
    local n; read -r n < "$TMP_TEST/echo-count"; n=$((n+1)); printf '%s\n' "$n" > "$TMP_TEST/echo-count"
    if [ "$n" -eq 1 ]; then cat "$REAL_FX/idle.txt"
    elif [ "$mode" = duplicate ]; then cat "$FX/triplicated.txt"
    elif [ "$n" -ge 4 ] && [ "$mode" = delayed ]; then cat "$FX/wrapped-two.txt"
    else cat "$REAL_FX/idle.txt"; fi
  }
  printf '0\n' > "$TMP_TEST/echo-count"; : > "$TMP_TEST/delayed.calls"
  TCO_RELAY_ECHO_POLLS=4 TCO_RELAY_ECHO_GAP=0 _tco_send_text_submit 01 v:.0 "$relay" C-m yes >/dev/null 2>&1 || rc=$?
  polls_seen="$(cat "$TMP_TEST/echo-count")"
  if [ "$rc" -eq 0 ]; then
    # Tras submit el texto pasa al transcript y el compositor queda vacío.
    tco_cap_pane_e() { printf '%s\n' "$relay"; cat "$REAL_FX/idle.txt"; }
    delivery=0; tco_verify_delivered 01 v:.0 1 "$relay" yes || delivery=$?
  fi
  printf '%s:%s:%s:%s:%s' "$rc" "$polls_seen" "$(grep -c ' -l --' "$TMP_TEST/delayed.calls")" "$(grep -c 'C-m' "$TMP_TEST/delayed.calls")" "$delivery"
)
ok 'eco al tercer sondeo entrega con un tecleo y un submit' "$(_delayed_echo_test delayed)" 0:4:1:1:0
ok 'eco ausente al tope es ambiguo sin submit' "$(_delayed_echo_test absent)" 2:5:1:0:-
ok 'eco duplicado no recibe submit ni segundo tecleo' "$(_delayed_echo_test duplicate)" 2:5:1:0:-

# shellcheck source=/dev/null
. "$SC/watch-carril.sh"
header="$(tco_stop_audit_header ABC-1234)"
ok 'cabecera canónica conserva contrato' "$header" 'STOP-AUDIT — ABC-1234 · informe pre-push'
brief="$(TCO_TF_MANIFEST="$TMP_TEST/docs.conf" TCO_REPO_STACK=ninguno tco_dispatch_instance_blocks "$template" | sed 's/__ISSUE__/ABC-1234/g')"
ok 'brief imprime cabecera compartida una vez' "$(printf '%s\n' "$brief" | grep -cF "$header")" 1
ok 'monitor reconoce cabecera emitida por brief' "$(printf '%s\n' "$brief" | grep -cE "$(tco_watch_pattern stop-audit)")" 1
ok 'extractor reconoce cabecera emitida por brief' "$( { printf '%s\n' "$header" 'Informe'; sed -n '/^───/,$p' "$REAL_FX/idle.txt"; } | tco_extract_stop_audit)" "$header
Informe"
ok 'monitor no reconoce cita conversacional' "$(printf 'Estoy en STOP-AUDIT\n' | grep -cE "$(tco_watch_pattern stop-audit)")" 0

_baseline_cleanup_test() {
  set -u
  local sender="$1" send_result="$2" rc=0
  mktemp() { printf '%s\n' "$TMP_TEST/baseline-$sender"; }
  incus() { :; }
  sleep() { :; }
  tco_wait_idle() { return 0; }
  tco_pane_busy() { return 1; }
  tco_clear_input() { :; }
  tco_cap_pane() { cat "$REAL_FX/idle.txt"; }
  tco_cap_pane_e() { cat "$REAL_FX/idle.txt"; }
  tco_delivery_baseline() { : > "$4"; return 1; }
  _tco_send_text_submit() { printf 'tecleo\n' >> "$TMP_TEST/baseline-calls"; return "$send_result"; }
  tco_verify_delivered() { printf 'entrega\n' > "$TMP_TEST/delivery-receipt"; return 0; }
  : > "$TMP_TEST/baseline-calls"
  if [ "$sender" = single ]; then tco_send_dev 01 v:.0 texto >/dev/null 2>&1 || rc=$?
  else tco_relay_file 01 v:.0 "$REAL_FX/idle.txt" brief >/dev/null 2>&1 || rc=$?; fi
  unrelated_return() { :; }
  unrelated_return
  printf '%s:%s:%s' "$rc" "$([ -e "$TMP_TEST/baseline-$sender" ] && echo pendiente || echo limpio)" "$(grep -c tecleo "$TMP_TEST/baseline-calls")"
}
for sender in single file; do
  ok "baseline $sender limpia con nounset tras éxito y retorno ajeno" "$(_baseline_cleanup_test "$sender" 0; printf ':%s' "$?")" 0:limpio:1:0
  ok "baseline $sender limpia tras ambigüedad sin segundo tecleo" "$(_baseline_cleanup_test "$sender" 2; printf ':%s' "$?")" 2:limpio:1:0
done

# La configuración regional pertenece al proceso de prueba; cada función debe conservarla.
for locale in C C.UTF-8; do
  for state in idle busy modal redraw done t-1 t-3 t-5; do
    case "$state" in idle|done) expected=1 ;; modal|redraw) expected=2 ;; *) expected=0 ;; esac
    file="$REAL_FX/$state.txt"
    ok "ocupado independiente de locale $locale $state" "$(export LC_ALL="$locale"; tco_pane_busy_from < "$file" >/dev/null; echo $?)" "$expected"
    reference="$(export LC_ALL=C.UTF-8; tco_tui_anchor_from < "$file"; printf '\nrc=%s' "$?")"
    ok "ancla independiente de locale $locale $state" "$(export LC_ALL="$locale"; tco_tui_anchor_from < "$file"; printf '\nrc=%s' "$?")" "$reference"
    for region in transcript composer status; do
      reference="$(export LC_ALL=C.UTF-8; tco_tui_regions_from "$region" < "$file"; printf '\nrc=%s' "$?")"
      ok "región independiente de locale $locale $state $region" "$(export LC_ALL="$locale"; tco_tui_regions_from "$region" < "$file"; printf '\nrc=%s' "$?")" "$reference"
    done
    ok "extractor sin informe conserva rc $locale $state" "$(export LC_ALL="$locale"; tco_extract_stop_audit < "$file" >/dev/null; echo $?)" 1
    ok "funciones conservan locale del llamador $locale $state" "$(
      export LC_ALL="$locale"
      tco_pane_busy_from < "$file" >/dev/null || :
      tco_tui_anchor_from < "$file" >/dev/null || :
      tco_tui_regions_from composer < "$file" >/dev/null || :
      tco_extract_stop_audit < "$file" >/dev/null || :
      printf '%s' "$LC_ALL"
    )" "$locale"
    case "$state" in modal|redraw) continue ;; esac
    reference="$(LC_ALL=C.UTF-8 tco_tui_regions_from transcript < "$file")"
    ok "extractor corta captura real con locale $locale $state" "$(
      export LC_ALL="$locale"
      { printf 'STOP-AUDIT — ABC-1234 · informe pre-push\n'; cat "$file"; } | tco_extract_stop_audit
    )" "STOP-AUDIT — ABC-1234 · informe pre-push
$reference"
  done
  old_chrome=$'STOP-AUDIT — ABC-1234 · informe pre-push\nInforme completo\n╭──╮\n❯\n╰──╯\nbypass permissions · ? for shortcuts'
  ok "ancla con esquinas y locale $locale" "$(export LC_ALL="$locale"; printf '%s\n' "$old_chrome" | tco_tui_anchor_from)" '3 5'
  ok "región con esquinas y locale $locale" "$(export LC_ALL="$locale"; printf '%s\n' "$old_chrome" | tco_tui_regions_from composer)" '❯'
  ok "extractor con esquinas y locale $locale" "$(export LC_ALL="$locale"; printf '%s\n' "$old_chrome" | tco_extract_stop_audit)" $'STOP-AUDIT — ABC-1234 · informe pre-push\nInforme completo'
  ok "busy con consejo y locale $locale" "$(export LC_ALL="$locale"; tco_pane_busy_from < "$FX/busy.txt"; echo $?)" 0
done

printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] && [ "$((PASS+FAIL))" -eq 461 ]
