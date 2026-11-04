#!/usr/bin/env bash
# Reposo sin estado y reanudación tras GO; solo dentro del arnés.
# shellcheck disable=SC2329,SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/../scripts"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "${TCO_REST_LIB:-$SC/lib.sh}"
# shellcheck source=/dev/null
. "$SC/watch-carril.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# watch-carril carga la librería vigente; la base roja se carga después.
if [ -n "${TCO_REST_LIB:-}" ]; then
  # shellcheck source=/dev/null
  . "$TCO_REST_LIB"
  unset -f tco_relay_plan_go
fi
TMP_TEST="$(mktemp -d)"; trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}
FIXTURE="$HERE/fixtures/reposo/p32-dev-contexto.txt"
ok 'pantalla real neutralizada pasa escáner' "$(tco_fixture_secret_scan < "$FIXTURE"; echo $?)" 0
sleep() { :; }
tco_cap_pane() {
  local n; n="$(cat "$TMP_TEST/polls")"; n=$((n+1)); printf '%s' "$n" > "$TMP_TEST/polls"
  if [ "$n" -ge "$pattern_at" ]; then printf '%s\n' "$found_text"; else cat "$FIXTURE"; fi
}
tco_pane_busy() {
  local n rc; n="$(cat "$TMP_TEST/busy")"; n=$((n+1)); printf '%s' "$n" > "$TMP_TEST/busy"
  read -r -a states <<< "$busy_states"; rc="${states[n-1]:-${states[-1]}}"; return "$rc"
}
monitor() {
  local rc=0 busy_states="$1" pattern_at="$2" found_text="$3"; local -a states
  printf 0 > "$TMP_TEST/polls"; printf 0 > "$TMP_TEST/busy"
  tco_wait_state 01 v:.0 "$4" 0 "${5:-8}" "${6:-${TCO_WAIT_IDLE_POLLS:-3}}" > "$TMP_TEST/out" 2> "$TMP_TEST/err" || rc=$?
  printf '%s' "$rc"
}
ok 'reposo sostenido sin patrón tiene rc propio' "$(monitor '1' 99 STOP-AUDIT STOP-AUDIT)" 3
ok 'reposo corta tras tres comparaciones estables' "$(cat "$TMP_TEST/polls")" 4
ok 'recorte incluye pregunta real final' "$(grep -c '¿Lo ejecuto tal cual' "$TMP_TEST/out")" 1
ok 'diagnóstico exige leer y actuar' "$(grep -c 'lee su última respuesta y actúa' "$TMP_TEST/err")" 1
ok 'ocupado y luego patrón' "$(monitor '0' 4 STOP-AUDIT STOP-AUDIT)" 0
ok 'un sondeo de reposo luego ocupado sigue esperando' "$(monitor '1 0 0 0' 5 STOP-AUDIT STOP-AUDIT)" 0
ok 'desconocido reinicia contador de reposo' "$(monitor '1 1 2 1 1' 6 STOP-AUDIT STOP-AUDIT)" 0
ok 'plan-listo con diálogo tiene prioridad sobre reposo' "$(monitor '1' 1 'Would you like to proceed' "$(tco_watch_pattern plan-listo)" 3 1)" 0
ok 'pregunta abierta tiene prioridad sobre reposo' "$(monitor '1' 1 'Enter to select' "$(tco_watch_pattern pregunta)" 3 1)" 0
ok 'permiso abierto tiene prioridad sobre reposo' "$(monitor '1' 1 'Do you want to proceed?' "$(tco_watch_pattern permiso)" 3 1)" 0
ok 'tiempo agotado siempre ocupado' "$(monitor '0' 99 STOP-AUDIT STOP-AUDIT 4)" 1
ok 'tiempo agotado desconocido no declara reposo' "$(monitor '2' 99 STOP-AUDIT STOP-AUDIT 4)" 1
ok 'umbral configurable por argumento' "$(monitor '1' 99 STOP-AUDIT STOP-AUDIT 4 2)" 3
ok 'umbral por entorno' "$(TCO_WAIT_IDLE_POLLS=1 monitor '1' 99 STOP-AUDIT STOP-AUDIT 4 '')" 3
ok 'umbral cero rechazado' "$(monitor '1' 99 STOP-AUDIT STOP-AUDIT 4 0)" 2

# Informes largos y resultados del turno actual.
LONG="$HERE/fixtures/reposo/p37-dev-cola.txt"
ok 'informe real neutralizado pasa escáner' "$(tco_fixture_secret_scan < "$LONG"; echo $?)" 0
_tco_carril_session() { [ "$disk" = yes ] && printf 'sesion-neutra idle ahora version\n'; }
_tco_carril_response_records() { cat "$TMP_TEST/records"; }
tco_cap_pane() { cat "$TMP_TEST/screen"; }
tco_pane_busy() { return 1; }
long_monitor() {
  local rc=0
  tco_wait_state 01 v:.0 "$(tco_watch_pattern "$1")" 0 3 1 "$1" > "$TMP_TEST/out" 2> "$TMP_TEST/err" || rc=$?
  printf '%s' "$rc"
}
disk=no
{ printf '❯ encargo vigente\n'; cat "$LONG"; } > "$TMP_TEST/screen"
ok 'informe largo real en reposo detectado' "$(long_monitor stop-audit)" 0
ok 'monitor imprime bloque SHA' "$(grep -c 'SHA auditado:' "$TMP_TEST/out")" 1
printf '\n❯ nuevo encargo\n● Tengo una pregunta pendiente\n' >> "$TMP_TEST/screen"
ok 'informe seguido de turno nuevo no vale en pane' "$(long_monitor stop-audit)" 3
{ printf '❯ encargo vigente\n'; grep -v 'SHA auditado:' "$LONG"; } > "$TMP_TEST/screen"
ok 'informe incompleto sin SHA no vale' "$(long_monitor stop-audit)" 3
cat "$LONG" > "$TMP_TEST/screen"
disk=yes
jq -n -c '{type:"user",sessionId:"sesion-neutra",uuid:"human-current",message:{content:"encargo vigente"}}' > "$TMP_TEST/records"
jq -Rs -c '{type:"assistant",sessionId:"sesion-neutra",uuid:"answer-current",parentUuid:"human-current",message:{content:[{type:"text",text:.}]}}' < "$LONG" >> "$TMP_TEST/records"
ok 'informe del transcript vivo tiene prioridad' "$(long_monitor stop-audit)" 0
jq -n -c '{type:"user",sessionId:"sesion-neutra",uuid:"human-new",message:{content:"otro turno sin informe"}}' >> "$TMP_TEST/records"
ok 'turno nuevo en disco impide rescate del pane viejo' "$(long_monitor stop-audit)" 3
printf 'registro roto\n' >> "$TMP_TEST/records"
ok 'corrupción del turno impide rescate del pane' "$(long_monitor stop-audit)" 3
for state in pr merge; do
  if [ "$state" = pr ]; then text='https://github.com/org-neutra/repo/pull/12'; else text='pull request merged'; fi
  jq -n -c '{type:"user",sessionId:"sesion-neutra",uuid:"human-current",message:{content:"encargo vigente"}}' > "$TMP_TEST/records"
  jq -n -c --arg text "$text" '{type:"assistant",sessionId:"sesion-neutra",uuid:"answer-current",parentUuid:"human-current",message:{content:$text}}' >> "$TMP_TEST/records"
  ok "$state por disco sobre turno largo" "$(long_monitor "$state")" 0
  jq -n -c '{type:"user",sessionId:"sesion-neutra",uuid:"human-new",message:{content:"nuevo encargo"}}' >> "$TMP_TEST/records"
  ok "$state de turno anterior rechazado" "$(long_monitor "$state")" 3
done
disk=no
cat "$LONG" > "$TMP_TEST/screen"
printf 0 > "$TMP_TEST/race"
tco_pane_busy() {
  local n; n="$(cat "$TMP_TEST/race")"; n=$((n+1)); printf '%s' "$n" > "$TMP_TEST/race"
  [ "$n" -gt 1 ] && return 0
  return 1
}
ok 'ocupado durante lectura no declara reposo sin informe' "$(long_monitor stop-audit)" 1
unset -f _tco_carril_session _tco_carril_response_records

# Transporte doble: librería real para relevo, disponibilidad, eco y submit.
unset -f tco_cap_pane tco_pane_busy
REAL="$HERE/fixtures/pane/claude_2.1.289/idle.txt"
capture() {
  local text; text="$(cat "$TMP_TEST/text")"
  if [ -n "$text" ]; then sed "s|^❯.*|❯ $text|" "$REAL"; else cat "$REAL"; fi
}
tco_cap_pane() { capture; }
tco_cap_pane_e() { capture; }
tco_pane_busy() {
  if [ "$resume_busy" = yes ] && grep -q '^informe-confirmado$' "$TMP_TEST/events"; then
    printf 'ocupado-tras-informe\n' >> "$TMP_TEST/events"; resume_busy=no; return 0
  fi
  return 1
}
tmux() {
  if [ "$1" = texto ]; then
    printf '%s' "$2" > "$TMP_TEST/text"; printf 'texto:%s\n' "$2" >> "$TMP_TEST/keys"
  else
    printf '%s\n' "$1" >> "$TMP_TEST/keys"; : > "$TMP_TEST/text"
  fi
}
incus() {
  local command="${8:-}"
  if [[ "$command" == 'tmux send-keys '* ]]; then
    if [[ "$command" == *' -l -- '* ]]; then tmux texto "${*: -1}"; else tmux C-m; fi
  fi
  return 0
}
tco_delivery_baseline() { : > "$4"; }
_tco_carril_session() { printf 'sesion-neutra idle 1'; }
_tco_carril_response_records() { cat "$TMP_TEST/records"; }
tco_verify_delivered() {
  if [[ "$4" == audit2dev.* ]]; then
    printf 'informe-confirmado\n' >> "$TMP_TEST/events"
    jq -nc '{type:"user",sessionId:"sesion-neutra",uuid:"human-relay",message:{content:"lee relevo"}}' > "$TMP_TEST/records"
    [ -z "${6:-}" ] || printf 'human-relay\n' > "$6"
    [ "$foreign" != yes ] || printf 'texto ajeno' > "$TMP_TEST/text"
  else
    printf 'orden-confirmada\n' >> "$TMP_TEST/events"
    [ "$uncertain" != yes ] || return 1
  fi
}
resume_case() {
  local rc=0 foreign="$1" uncertain="${2:-no}" resume_busy="${3:-no}"
  : > "$TMP_TEST/keys"; : > "$TMP_TEST/text"; : > "$TMP_TEST/events"
  jq -nc '{type:"user",sessionId:"sesion-neutra",uuid:"human-current",message:{content:"plan propio"}}' > "$TMP_TEST/records"
  printf 'informe no confiable\n' > "$TMP_TEST/report"
  tco_relay_plan_go 01 v:.0 "$TMP_TEST/report" > "$TMP_TEST/result" 2>&1 || rc=$?
  printf 'REGISTRO reanudación rc=%s\n' "$rc"; cat "$TMP_TEST/keys"; cat "$TMP_TEST/events"
  printf '%s' "$rc" > "$TMP_TEST/rc"
}
resume_case no no yes
ok 'secuencia tras visto bueno reanuda' "$(cat "$TMP_TEST/rc")" 0
EXPECTED='texto:El plan está aprobado. El cambio de modelo interrumpió a propósito tu orden en curso: repítela y continúa la implementación hasta el informe previo a la entrega.'
ok 'último texto es instrucción fija de reanudar' "$(grep '^texto:' "$TMP_TEST/keys" | tail -1)" "$EXPECTED"
ok 'instrucción fija enviada una sola vez' "$(grep -c '^texto:El plan está aprobado' "$TMP_TEST/keys")" 1
ok 'informe precede a orden de reanudar' "$(grep '^texto:' "$TMP_TEST/keys" | head -1 | grep -c '^texto:lee .*audit2dev')" 1
ok 'submit separado de cada texto' "$(grep -c '^C-m$' "$TMP_TEST/keys")" 2
ok 'espera reposo después del informe confirmado' "$(paste -sd ',' "$TMP_TEST/events")" 'informe-confirmado,ocupado-tras-informe,orden-confirmada'
resume_case yes
ok 'compositor ajeno tras informe devuelve rc 2' "$(cat "$TMP_TEST/rc")" 2
ok 'compositor ajeno no recibe reanudación' "$(grep -c '^texto:El plan está aprobado' "$TMP_TEST/keys")" 0
ok 'compositor ajeno se conserva' "$(cat "$TMP_TEST/text")" 'texto ajeno'
resume_case no yes
ok 'entrega incierta escala' "$(cat "$TMP_TEST/rc")" 2
ok 'entrega incierta no duplica orden' "$(grep -c '^texto:El plan está aprobado' "$TMP_TEST/keys")" 1
printf 'RESULTADO reposo: PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$((PASS+FAIL))" -eq 40 ] && [ "$FAIL" -eq 0 ]
