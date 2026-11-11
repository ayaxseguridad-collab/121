#!/usr/bin/env bash
# Plan (regla 17) con el CLI en `status=waiting`: el ExitPlanMode PENDIENTE no está en el transcript (Claude Code
# 2.1.318 lo vuelca con su `tool_result`, cuando el humano contesta el diálogo), así que el plan vigente solo existe
# en pantalla. Cubre el detector del diálogo de plan, el rc 6 de tco_plan_from_transcript, la captura acotada y el
# rc 21 (plan idéntico a una ronda ya auditada). Solo dentro del arnés; sin flota (seams inyectados).
# Fixtures REALES de 2.1.318 (ensayo e2, 5-nov-2026): plan-dialog.txt (captura del diálogo), session-waiting.json
# (sessions/<pid>.json con status=waiting) y exitplan-plan.txt (input.plan real de los ExitPlanMode #2 y #3, que eran
# IDÉNTICOS). Las variantes se derivan en un temporal y nunca entran en fixtures/.
# shellcheck disable=SC2034,SC2016,SC2329,SC2030,SC2031
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$TEST_DIR/../scripts"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "$SC/lib.sh"
# shellcheck source=/dev/null
. "$SC/extract-plan.sh"
FXD="$TEST_DIR/fixtures/pane/claude_2.1.318"
IDLE="$TEST_DIR/fixtures/pane/claude_2.1.302/idle.txt"
DLG="$FXD/plan-dialog.txt"
T="$(mktemp -d "${TMPDIR:-/tmp}/tco-plan-pantalla.XXXXXX")"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
TOTAL_ESPERADO=79
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}

# --- registros del transcript (mismos helpers que tests/run-tests.sh) y los que solo aparecen en 2.1.318 ---
_ep_exit()  { jq -nc --arg p "$1" --arg id "${2:-toolu_ep}" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:$id,name:"ExitPlanMode",input:{plan:$p,planFilePath:"/x/plans/p.md"}}]}}'; }
_ep_rej()   { jq -nc --arg id "${1:-toolu_ep}" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,is_error:true,content:"The user doesn'"'"'t want to proceed with this tool use. The tool use was rejected."}]}}'; }
_ep_appr()  { jq -nc --arg id "${1:-toolu_ep}" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,content:"User has approved your plan. You can now start coding."}]}}'; }
_ep_user()  { jq -nc --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
_ep_irq()   { jq -nc '{type:"user",message:{role:"user",content:[{type:"text",text:"[Request interrupted by user for tool use]"}]}}'; }
_ep_sys()   { jq -nc '{type:"system",subtype:"turn_duration"}'; }
_ep_apireq() { jq -nc '{type:"api-request"}'; }
_ep_atext() { jq -nc --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
_ep_atool() { jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"toolu_b",name:"Read",input:{file_path:"/x"}}]}}'; }
_ep_tres()  { jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_b",content:"ok"}]}}'; }
_ep_plan() { printf 'PLAN-INICIO %s\n' "$1"; local i; for i in 1 2 3 4 5 6 7 8 9 10; do printf 'paso %s %s\n' "$i" "$2"; done; printf 'PLAN-FIN\n'; }
# Secuencia real de e2 tras dos rechazos: el humano relevó el NO-GO y el dev tiene el plan pendiente sin volcar.
_ep_seq_e2() { # $1 = plan de #1 y #2
  _ep_user "presenta"; _ep_exit "$1" toolu_1; _ep_rej toolu_1; _ep_irq; _ep_sys
  _ep_exit "$1" toolu_2; _ep_rej toolu_2; _ep_irq; _ep_sys
  _ep_user "lee el relevo del NO-GO e incorpóralo"; _ep_atool; _ep_tres; _ep_apireq
}

# --- seams del extractor (patrón de run-tests.sh) ---
_ep_reset() {
  EP_N=$((${EP_N:-0}+1)); export TCO_RUNS_DIR="$T/runs$EP_N"; mkdir -p "$TCO_RUNS_DIR"
  : > "$T/cap.log"; : > "$T/gate.log"; : > "$T/rec.log"
  rm -f "$T"/recs.* "$T/screen" "$T"/screen.* "$T/out" "$T/gate.artifact"
  : > "$T/screen"
  EP_SESS="sessA"; EP_BUSY=1; EP_VERDICT="GO"; EP_STATUS="busy"
}
tco_pane_busy() { return "$EP_BUSY"; }
tco_pane_dev()  { printf 'v:.0'; }
_tco_carril_session() { [ "$EP_SESS" = none ] && return 1; printf '%s %s 2026-01-01T00:00:00.000Z 2.1.318\n' "$EP_SESS" "$EP_STATUS"; }
_tco_carril_exitplan_records() { printf '%s\n' "$2" >> "$T/rec.log"; [ -f "$T/recs.$2" ] || return 1; cat "$T/recs.$2"; }
tco_cap_pane() { printf '%s\n' "$3" >> "$T/cap.log"; if [ -f "$T/screen.$3" ]; then cat "$T/screen.$3"; else cat "$T/screen"; fi; }
_tco_plan_gate() { printf '%s\n' "$*" >> "$T/gate.log"; cp "$3" "$T/gate.artifact"; printf 'literal\n' > "$5"; printf '%s' "$EP_VERDICT"; }
_ep_run() { tco_extract_plan 01 ABC-9001 "$T/out" >"$T/stdout" 2>"$T/stderr"; echo $?; }
_ep_lines() { wc -l < "$1" | tr -d ' '; }
# Pantalla del dev con el diálogo pendiente: el plan renderizado (sangría de 1 espacio) y la COLA REAL de la captura
# (desde la raya `╌` hasta el pie, sin compositor).
sed -n '/^╌/,$p' "$DLG" > "$T/tail"
_mkscreen() { printf '%s\n' "$1" | sed -e 's/^/ /'; cat "$T/tail"; }
# Render del TUI para un plan en bruto: sin `#`, sin `**`, sin backticks, sangría de 1 espacio.
_render() { printf '%s\n' "$1" | sed -e 's/^#\{1,6\} //' -e 's/\*\*//g' -e 's/`//g' -e 's/^/ /'; }
hrc() { local rc=0; tco_plan_dialog_head_from >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

PA="$(_ep_plan ABC-9001 PLAN-A)"; PB="$(_ep_plan ABC-9001 PLAN-B)"; PC="$(_ep_plan ABC-9001 PLAN-C)"; PD="$(_ep_plan ABC-9001 PLAN-D)"
PG="$(_ep_plan ABC-9001 'si a < b')"; PH="$(_ep_plan ABC-9001 'si a > b')"
PLAN_REAL="$(cat "$FXD/exitplan-plan.txt")"

echo "-- A. detector del diálogo de plan abierto: captura REAL de 2.1.318 y variantes --"
ok "real 2.1.318: diálogo abierto y completo, PLAN-FIN pegado -> rc 0" "$(hrc < "$DLG")" 0
ok "real: el head acaba en el plan (1 PLAN-FIN) y no incluye el título" "$(tco_plan_dialog_head_from < "$DLG" | grep -c 'PLAN-FIN'):$(tco_plan_dialog_head_from < "$DLG" | grep -c 'Would you like')" "1:0"
ok "real con secuencias ANSI -> rc 0" "$(sed -e 's/^/\x1b[2m/' -e 's/$/\x1b[0m/' "$DLG" | hrc)" 0
ok "captura vacía -> rc 1" "$(printf '' | hrc)" 1
ok "diálogo ya contestado (compositor de reposo debajo) -> rc 1" "$(cat "$DLG" "$IDLE" | hrc)" 1
ok "sin pie ni continuación -> rc 1" "$(grep -v -e 'shift+tab to approve' -e 'ctrl+g to edit' "$DLG" | hrc)" 1
ok "opciones 1 y 3 (falta la 2) -> rc 1" "$(grep -v 'manually approve' "$DLG" | hrc)" 1
ok "sin cursor ❯ -> rc 1" "$(sed 's/❯ 1\./  1./' "$DLG" | hrc)" 1
ok "dos cursores ❯ -> rc 1" "$(sed 's/^   2\./ ❯ 2./' "$DLG" | hrc)" 1
ok "título citado en prosa, sin opciones -> rc 1" "$(printf ' PLAN-FIN\n Claude has written up a plan and is ready to execute. Would you like to proceed?\n' | hrc)" 1
ok "línea ajena tras el pie -> rc 1" "$({ cat "$DLG"; printf ' texto ajeno\n'; } | hrc)" 1
ok "PLAN-FIN no pegado al diálogo (prosa entre medias) -> rc 2" "$(sed 's/^╌/ nota ajena\n╌/' "$DLG" | hrc)" 2
ok "diálogo sin ningún PLAN-FIN encima -> rc 2" "$(grep -v 'PLAN-FIN' "$DLG" | hrc)" 2
TWOBLK="$({ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n paso x PLAN-N\n PLAN-FIN\n'; cat "$T/tail"; })"
ok "dos bloques: el head es SOLO el pegado al diálogo (ni rastro del bloque viejo, un solo PLAN-FIN)" "$(printf '%s\n' "$TWOBLK" | tco_plan_dialog_head_from | grep -c 'PLAN-A'):$(printf '%s\n' "$TWOBLK" | tco_plan_dialog_head_from | grep -c 'PLAN-FIN'):$(printf '%s\n' "$TWOBLK" | tco_plan_dialog_head_from | grep -c 'PLAN-N')" "0:1:1"
ok "fixture plan-dialog.txt pasa tco_fixture_secret_scan" "$(tco_fixture_secret_scan < "$DLG" >/dev/null 2>&1; echo $?)" 0
ok "fixture exitplan-plan.txt pasa tco_fixture_secret_scan" "$(tco_fixture_secret_scan < "$FXD/exitplan-plan.txt" >/dev/null 2>&1; echo $?)" 0
ok "fixture session-waiting.json pasa tco_fixture_secret_scan" "$(tco_fixture_secret_scan < "$FXD/session-waiting.json" >/dev/null 2>&1; echo $?)" 0

echo "-- A'. datos reales de e2 --"
RAWTAIL="$(sed -n '/^## Cambios tras/,/^PLAN-FIN/p' "$FXD/exitplan-plan.txt")"
RENDTAIL="$(sed -n '/^ Cambios tras/,/^ PLAN-FIN/p' "$DLG")"
ok "final del plan en BRUTO vs su render real del TUI: NO coinciden con el criterio de espacios (dirección segura: se audita de más)" "$([ "$(printf '%s\n' "$RAWTAIL" | _tco_plan_norm)" != "$(printf '%s\n' "$RENDTAIL" | _tco_plan_norm)" ] && [ -n "$RAWTAIL" ] && echo distinto || echo igual)" distinto
ok "session-waiting.json: status/waitingFor del CLI con el diálogo abierto" "$(jq -r '.status + "/" + .waitingFor' "$FXD/session-waiting.json")" "waiting/permission prompt"
WSEC="$(jq -r '.statusUpdatedAt' "$FXD/session-waiting.json")"
REJ2="$(( $(date -u -d 2026-11-05T19:21:27Z +%s) * 1000 + 995 ))"; REJ3="$(( $(date -u -d 2026-11-05T19:45:53Z +%s) * 1000 ))"
ok "el estado waiting es POSTERIOR al rechazo del #2 (19:21:27.995Z) y anterior al del #3 (19:45:53Z)" "$([ "$WSEC" -gt "$REJ2" ] && [ "$WSEC" -lt "$REJ3" ] && echo si || echo no)" si

echo "-- B. ledger de rondas auditadas --"
_led() { local o rc=0; o="$(_tco_plan_ledger_equal "$@")" || rc=$?; printf '%s:%s' "$rc" "$o"; }
export TCO_RUNS_DIR="$T/runs-led"; mkdir -p "$TCO_RUNS_DIR"
# El ledger guarda el texto que se GATEÓ: el de pantalla (con la sangría de 1 espacio del TUI), no el crudo.
_render "$PA" > "$TCO_RUNS_DIR/plan-01-ABC-9001-r1.norm"
_render "$PB" > "$TCO_RUNS_DIR/plan-01-ABC-9001-r2.norm"
_render "$PC" > "$TCO_RUNS_DIR/plan-01-ABC-9001-r3.norm"
_render "$PD" > "$TCO_RUNS_DIR/plan-01-ABC-9001-r4.pending"
_render "$PD" > "$TCO_RUNS_DIR/plan-01-ABC-7777-r1.norm"
_render "$PG" > "$TCO_RUNS_DIR/plan-01-ABC-9001-r5.norm"
_render "$PA" > "$T/cut-a"; _render "$PB" > "$T/cut-b"; _render "$PD" > "$T/cut-d"; : > "$T/cut-vacio"
_render "$PG" > "$T/cut-g"; _render "$PH" > "$T/cut-h"
{ _render "$PA" | sed 's/$/  \r/'; printf '\n\n  \n'; } > "$T/cut-a-ws"
printf '%s\n' "$PA" > "$T/cut-a-crudo"
ok "plan igual (render del TUI) a una ronda ANTIGUA con otras más recientes -> igual, ronda 1" "$(_led "$T/cut-a" 01 ABC-9001)" "0:1"
ok "plan igual a la ronda 2 -> igual, ronda 2" "$(_led "$T/cut-b" 01 ABC-9001)" "0:2"
ok "plan nuevo: una .pending y la ronda de OTRO encargo no cuentan -> distinto" "$(_led "$T/cut-d" 01 ABC-9001)" "1:"
ok "plan vacío no iguala a nada" "$(_led "$T/cut-vacio" 01 ABC-9001)" "1:"
ok "solo difiere en espacios al final, CRLF y saltos finales -> igual (ronda 1)" "$(_led "$T/cut-a-ws" 01 ABC-9001)" "0:1"
ok "el mismo plan CRUDO (sin la sangría del TUI) contra el del ledger renderizado -> distinto (se audita de más)" "$(_led "$T/cut-a-crudo" 01 ABC-9001)" "1:"
ok "solo difiere en un '<' frente a un '>' -> distinto (el igual SÍ casa con la ronda 5)" "$(_led "$T/cut-g" 01 ABC-9001):$(_led "$T/cut-h" 01 ABC-9001)" "0:5:1:"

echo "-- C. tco_plan_from_transcript: rc 6 solo con el CLI en waiting --"
_tp() { local rc=0; tco_plan_from_transcript 01 >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
_ep_reset
{ _ep_user "presenta"; _ep_exit "$PA" toolu_1; _ep_rej toolu_1; } > "$T/recs.sessA"
EP_STATUS=waiting; ok "rechazado + waiting -> rc 6" "$(_tp)" 6
EP_STATUS=busy;    ok "rechazado + busy -> rc 2 (como hoy)" "$(_tp)" 2
EP_STATUS=idle;    ok "rechazado + idle -> rc 2 (como hoy)" "$(_tp)" 2
EP_STATUS=unknown; ok "rechazado + estado desconocido -> rc 2" "$(_tp)" 2
{ _ep_user "presenta"; _ep_exit "$PA" toolu_1; _ep_user "no, haz otra cosa"; } > "$T/recs.sessA"
EP_STATUS=waiting; ok "obsoleto + waiting -> rc 6" "$(_tp)" 6
{ _ep_user "presenta"; _ep_exit "$PA" toolu_1; _ep_appr toolu_1; } > "$T/recs.sessA"
EP_STATUS=waiting; ok "aprobado + waiting -> rc 3 (sin cambios)" "$(_tp)" 3
{ _ep_user "presenta"; _ep_exit "$PA" toolu_1; printf '{"truncada":\n'; } > "$T/recs.sessA"
EP_STATUS=waiting; ok "vigencia indeterminada + waiting -> rc 5 (sin cambios)" "$(_tp)" 5
# Texto con ancla de más de 64 KB (nivel 2): con grep -q + pipefail el printf recibía SIGPIPE y el texto se leía «sin ancla».
BIG="$(_ep_plan ABC-9001 GRANDE)"; _bi=0
while [ "$_bi" -lt 1900 ]; do BIG="$BIG"$'\n'"relleno $_bi xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; _bi=$((_bi+1)); done
{ _ep_user "presenta el plan"; _ep_atext "$BIG"; } > "$T/recs.sessA"; EP_STATUS=busy
ok "nivel 2: texto con ancla de más de 64 KB -> rc 0 (no se lee como «sin ancla» por SIGPIPE bajo pipefail)" "$([ "${#BIG}" -gt 65536 ] && echo grande || echo corto):$(_tp)" "grande:0"

echo "-- E. tco_extract_plan: caso 1 (el de e2), 2 (idéntico a uno auditado), 3 (sin estado/diálogo) y 4 (aprobado) --"
_ep_reset; _ep_seq_e2 "$PA" > "$T/recs.sessA"; EP_STATUS=waiting; _mkscreen "$PC" > "$T/screen"
ok "caso 1 (secuencia real de e2, plan nuevo solo en pantalla) -> rc 0" "$(_ep_run)" 0
ok "caso 1: origen=pantalla (transcript sin volcar) logueado" "$(grep -c 'origen=pantalla (transcript sin volcar)' "$T/stderr")" 1
ok "caso 1: el gate recibió el plan nuevo y ni rastro de los dos rechazados" "$(grep -c PLAN-C "$T/gate.artifact"):$(grep -c PLAN-A "$T/gate.artifact")" "10:0"
ok "caso 1: la ronda 1 queda consumida (.norm)" "$([ -f "$TCO_RUNS_DIR/plan-01-ABC-9001-r1.norm" ] && echo si || echo no)" si
ok "caso 1: UNA sola captura de pantalla (SB=2000)" "$(_ep_lines "$T/cap.log")" 1
_ep_reset; { _ep_user "presenta"; _ep_exit "$PA" toolu_1; _ep_user "no, mejor otra cosa"; } > "$T/recs.sessA"; EP_STATUS=waiting; _mkscreen "$PC" > "$T/screen"
ok "caso 1 con ExitPlanMode OBSOLETO (rc 4) + waiting -> rc 0" "$(_ep_run)" 0
_ep_reset; _ep_seq_e2 "$PLAN_REAL" > "$T/recs.sessA"; EP_STATUS=waiting
printf '%s\n' "$PA" > "$TCO_RUNS_DIR/plan-01-ABC-9001-r1.norm"
{ _render "$PLAN_REAL"; cat "$T/tail"; } > "$T/screen"
ok "caso 1b (e2 real: #3 == #2, rechazado y NUNCA auditado; el ledger solo tiene otro plan) -> rc 0, se audita" "$(_ep_run)" 0
ok "caso 1b: el gate recibió el plan real (encabezado de los cambios tras el NO-GO)" "$(grep -c 'Cambios tras el NO-GO (run' "$T/gate.artifact")" 1
# caso 2: idéntico a un plan ya AUDITADO. La ronda 1 sale de la pantalla (sin ExitPlanMode en el transcript), así que el
# ledger guarda el texto de pantalla y la ronda con el diálogo pendiente lo compara pantalla contra pantalla.
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"; _mkscreen "$PA" > "$T/screen"; _run1="$(_ep_run)"
_ep_seq_e2 "$PA" > "$T/recs.sessA"; EP_STATUS=waiting
ok "caso 2: idéntico al plan de la ronda 1 ya auditado -> rc 21" "$_run1:$(_ep_run)" "0:21"
ok "caso 2: el mensaje nombra la ronda y no se abrió el gate otra vez" "$(grep -c 'plan idéntico (salvo espacios en blanco) al de la ronda 1 ya auditado' "$T/stdout"):$(_ep_lines "$T/gate.log")" "1:1"
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"; _mkscreen "$PA" > "$T/screen"; _r1="$(_ep_run)"
_ep_user "otra" > "$T/recs.sessA"; _mkscreen "$PB" > "$T/screen"; _r2="$(_ep_run)"
_ep_seq_e2 "$PA" > "$T/recs.sessA"; EP_STATUS=waiting; _mkscreen "$PA" > "$T/screen"
ok "caso 2: idéntico a una ronda ANTIGUA (la 1) con la 2 distinta presente -> rc 21 y nombra la ronda 1" "$_r1$_r2:$(_ep_run):$(grep -c 'de la ronda 1 ya auditado' "$T/stdout")" "00:21:1"
# un plan que solo difiere en un '<' frente a un '>' SE AUDITA
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"; _mkscreen "$PG" > "$T/screen"; _g1="$(_ep_run)"
_ep_seq_e2 "$PG" > "$T/recs.sessA"; EP_STATUS=waiting; _mkscreen "$PH" > "$T/screen"
ok "caso 2: solo difiere en un '<' frente a un '>' -> se AUDITA (rc 0, el gate se abre otra vez), no da 21" "$_g1:$(_ep_run):$(_ep_lines "$T/gate.log")" "0:0:2"
# dos bloques en la captura: el plan pendiente es SOLO el pegado al diálogo
_ep_reset; _ep_seq_e2 "$PB" > "$T/recs.sessA"; EP_STATUS=waiting
{ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n paso x PLAN-N\n PLAN-FIN\n'; cat "$T/tail"; } > "$T/screen"
ok "dos bloques: el pendiente SIN ancla no se sustituye por el bloque viejo anclado -> rc 11 y gate sin abrir" "$(_ep_run):$(_ep_lines "$T/gate.log")" "11:0"
_ep_reset; _ep_seq_e2 "$PB" > "$T/recs.sessA"; EP_STATUS=waiting
{ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n'; printf '%s\n' "$PC" | sed -e 's/^/ /'; cat "$T/tail"; } > "$T/screen"
ok "dos bloques: el pendiente anclado -> rc 0 y el gate recibe SOLO el pendiente" "$(_ep_run):$(grep -c PLAN-C "$T/gate.artifact"):$(grep -c PLAN-A "$T/gate.artifact")" "0:10:0"
# el RESPALDO de pantalla sin rc 6 (sin estado waiting): el bloque cortado tiene que ser el último de la captura
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n paso x PLAN-N\n PLAN-FIN\n'; } > "$T/screen"
ok "respaldo, dos bloques: el reciente SIN ancla no se sustituye por el viejo anclado -> rc 11 y gate sin abrir" "$(_ep_run):$(_ep_lines "$T/gate.log")" "11:0"
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n'; printf '%s\n' "$PC" | sed -e 's/^/ /'; } > "$T/screen"
ok "respaldo, dos bloques: el reciente anclado -> rc 0 y el gate recibe SOLO el reciente" "$(_ep_run):$(grep -c PLAN-C "$T/gate.artifact"):$(grep -c PLAN-A "$T/gate.artifact")" "0:10:0"
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n PLAN-INICIO ABC-9001\n paso 1 PLAN-N\n'; } > "$T/screen"
ok "respaldo: el reciente con ancla y SIN PLAN-FIN sigue dando rc 12 (no cae al bloque viejo) y el gate sin abrir" "$(_ep_run):$(_ep_lines "$T/gate.log")" "12:0"
# respaldo SIN diálogo y SIN waiting: [viejo anclado + su PLAN-FIN] y debajo [reciente SIN ancla y SIN PLAN-FIN]. La última
# ancla es la del viejo y tras ella hay UN solo PLAN-FIN, el del viejo: no puede gatearse el viejo mientras el humano ve el reciente.
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n paso 1 PLAN-N\n paso 2 PLAN-N\n paso 3 PLAN-N\n'; } > "$T/screen"
ok "respaldo: [viejo anclado + PLAN-FIN] + [reciente SIN ancla y SIN PLAN-FIN] -> rc 11, el gate NO recibe el viejo" "$(_ep_run):$(_ep_lines "$T/gate.log"):$([ -f "$T/gate.artifact" ] && grep -c PLAN-A "$T/gate.artifact" || echo -)" "11:0:-"
# el chrome real del prompt tras el PLAN-FIN (resumen del turno, compositor, estado y pie) NO se rechaza: cola de las capturas reales
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf '%s\n' "$PC" | sed -e 's/^/ /'; printf '\n'; sed -n '/Crunched for/,$p' "$TEST_DIR/fixtures/pane/claude_2.1.302/done.txt"; } > "$T/screen"
ok "respaldo: PLAN-FIN seguido del chrome real de 2.1.302 (resumen del turno, compositor, estado, pie) -> rc 0 y el gate recibe el plan" "$(_ep_run):$(grep -c PLAN-C "$T/gate.artifact")" "0:10"
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf '%s\n' "$PC" | sed -e 's/^/ /'; printf '\n'; sed -n '/Baked for/,$p' "$TEST_DIR/fixtures/pane/claude_2.1.289/done.txt"; } > "$T/screen"
ok "respaldo: PLAN-FIN seguido del chrome real de 2.1.289 (con «1 shell still running») -> rc 0 y el gate recibe el plan" "$(_ep_run):$(grep -c PLAN-C "$T/gate.artifact")" "0:10"
# respaldo CON el diálogo de plan abierto (el transcript no tiene ningún ExitPlanMode: el CLI no vuelca la primera presentación)
# (a) la primera presentación REAL de e2 (el input.plan real, con su render y la cola real del diálogo) -> gatea el reciente
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ _render "$PLAN_REAL"; cat "$T/tail"; } > "$T/screen"
ok "respaldo con el diálogo abierto: la primera presentación REAL de e2 -> rc 0, el gate se abre una vez y recibe ese plan" "$(_ep_run):$(_ep_lines "$T/gate.log"):$(grep -c 'Cambios tras el NO-GO (run' "$T/gate.artifact")" "0:1:1"
# (b) bloque viejo anclado con su PLAN-FIN encima + el reciente pegado al diálogo -> gatea SOLO el reciente
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n'; _mkscreen "$PC"; } > "$T/screen"
ok "respaldo con el diálogo abierto: viejo anclado + su PLAN-FIN encima y el reciente pegado al diálogo -> rc:aperturas:reciente:viejo = 0:1:10:0" "$(_ep_run):$(_ep_lines "$T/gate.log"):$(grep -c PLAN-C "$T/gate.artifact"):$(grep -c PLAN-A "$T/gate.artifact")" "0:1:10:0"
# (c) viejo anclado de ESTE encargo con su PLAN-FIN + el reciente pegado al diálogo con el ancla de OTRO encargo: el reciente no
# es un plan de ESTE encargo, así que no se gatea NADA (11) y, sobre todo, no el viejo. Imprime rc:aperturas:reciente:viejo.
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n'; _mkscreen "$(_ep_plan ABC-7777 AJENO)"; } > "$T/screen"
ok "respaldo con el diálogo abierto: viejo anclado + reciente con ancla de OTRO encargo -> rc:aperturas:reciente:viejo = 11:0:-:- (no se gatea el viejo)" "$(_ep_run):$(_ep_lines "$T/gate.log"):$([ -f "$T/gate.artifact" ] && grep -c AJENO "$T/gate.artifact" || echo -):$([ -f "$T/gate.artifact" ] && grep -c PLAN-A "$T/gate.artifact" || echo -)" "11:0:-:-"
# (d) viejo con ancla ANIDADA (dos PLAN-INICIO de este encargo antes de su PLAN-FIN) + el reciente sin ancla pegado al diálogo:
# con el atado al diálogo el head del reciente no trae ancla del encargo -> 11; sin recortar el head, el corte vería la anidada (13).
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf ' PLAN-INICIO ABC-9001\n'; printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n'; _mkscreen "$(printf ' paso x PLAN-N\n PLAN-FIN')"; } > "$T/screen"
ok "respaldo con el diálogo abierto: viejo con ancla ANIDADA + reciente sin ancla pegado al diálogo -> rc 11 (no 13) y gate sin abrir" "$(_ep_run):$(_ep_lines "$T/gate.log")" "11:0"
# (e) diálogo de plan abierto SIN PLAN-FIN pegado (el reciente sin cerrar) tras un viejo anclado con su PLAN-FIN: no se gatea el viejo
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"
{ printf '%s\n' "$PA" | sed -e 's/^/ /'; printf '\n paso 1 PLAN-N\n paso 2 PLAN-N\n'; cat "$T/tail"; } > "$T/screen"
ok "respaldo con el diálogo abierto SIN PLAN-FIN pegado (reciente sin cerrar) tras un viejo anclado -> rc 11 y gate sin abrir" "$(_ep_run):$(_ep_lines "$T/gate.log")" "11:0"
# la escalera del nivel 3 solo sube si el bloque no cabe en la ventana
_ep_reset; _ep_seq_e2 "$PB" > "$T/recs.sessA"; EP_STATUS=waiting
{ printf ' paso 9 PLAN-C\n paso 10 PLAN-C\n PLAN-FIN\n'; cat "$T/tail"; } > "$T/screen.2000"
_mkscreen "$PC" > "$T/screen.4000"
ok "escalera: con el INICIO fuera de la ventana de 2000 sube a 4000 (2 capturas) y el gate recibe el plan entero" "$(_ep_run):$(_ep_lines "$T/cap.log"):$(grep -c PLAN-C "$T/gate.artifact")" "0:2:10"
# caso 3: sin estado waiting no se mira la pantalla; con waiting, una captura y sin diálogo = 19
_ep_reset; { _ep_user "presenta"; _ep_exit "$PA" toolu_1; _ep_rej toolu_1; } > "$T/recs.sessA"; _mkscreen "$PB" > "$T/screen"
EP_STATUS=idle
ok "caso 3: rechazado + estado idle -> rc 19, cero capturas, gate sin abrir" "$(_ep_run):$(_ep_lines "$T/cap.log"):$(_ep_lines "$T/gate.log")" "19:0:0"
EP_STATUS=busy
ok "caso 3: rechazado + estado busy -> rc 19, cero capturas, gate sin abrir" "$(_ep_run):$(_ep_lines "$T/cap.log"):$(_ep_lines "$T/gate.log")" "19:0:0"
EP_STATUS=waiting; printf '%s\n' "$PB" > "$T/screen"
ok "caso 3: waiting pero SIN diálogo (plan suelto en pantalla) -> rc 19, UNA captura, gate sin abrir" "$(_ep_run):$(_ep_lines "$T/cap.log"):$(_ep_lines "$T/gate.log")" "19:1:0"
: > "$T/cap.log"; { _mkscreen "$PB"; cat "$IDLE"; } > "$T/screen"
ok "caso 3: waiting con el diálogo ya contestado (compositor debajo) -> rc 19, UNA captura" "$(_ep_run):$(_ep_lines "$T/cap.log")" "19:1"
: > "$T/cap.log"; : > "$T/screen"
ok "caso 3: waiting con la pantalla vacía -> rc 19 con el mensaje de hoy, UNA captura" "$(_ep_run):$(_ep_lines "$T/cap.log"):$(grep -c 'RECHAZADO u OBSOLETO' "$T/stdout")" "19:1:1"
: > "$T/cap.log"; { printf '%s\n' "$PB" | sed -e 's/^/ /'; printf ' nota ajena\n'; cat "$T/tail"; } > "$T/screen"
ok "caso 3: diálogo abierto sin PLAN-FIN pegado -> rc 12, gate sin abrir" "$(_ep_run):$(_ep_lines "$T/gate.log")" "12:0"
: > "$T/cap.log"; _mkscreen "$(_ep_plan ABC-7777 AJENO)" > "$T/screen"
ok "caso 3: diálogo abierto con el plan de OTRO encargo -> rc 11" "$(_ep_run)" 11
# caso 4 y demás invariantes
_ep_reset; { _ep_user "presenta"; _ep_exit "$PA" toolu_1; _ep_appr toolu_1; } > "$T/recs.sessA"; EP_STATUS=waiting; _mkscreen "$PB" > "$T/screen"
ok "caso 4: aprobado + waiting -> rc 20 sin cambios, cero capturas, gate sin abrir" "$(_ep_run):$(_ep_lines "$T/cap.log"):$(_ep_lines "$T/gate.log")" "20:0:0"
_ep_reset; { _ep_user "presenta"; _ep_exit "$PA" toolu_1; printf '{"truncada":\n'; } > "$T/recs.sessA"; EP_STATUS=waiting; _mkscreen "$PB" > "$T/screen"
ok "N-M1: vigencia indeterminada + waiting -> rc 19 sin cambios, cero capturas, gate sin abrir" "$(_ep_run):$(_ep_lines "$T/cap.log"):$(_ep_lines "$T/gate.log")" "19:0:0"
_ep_reset; _ep_user "presenta" > "$T/recs.sessA"; EP_STATUS=waiting; _mkscreen "$PB" > "$T/screen"
ok "ronda 1 sin ningún ExitPlanMode (+ waiting) -> rc 0 con origen RESPALDO y SIN «transcript sin volcar»" "$(_ep_run):$(grep -c 'origen=pantalla (RESPALDO' "$T/stderr"):$(grep -c 'transcript sin volcar' "$T/stderr")" "0:1:0"
_ep_reset; _ep_exit "$PA" > "$T/recs.sessA"; _s1="$(_ep_run)"
ok "staleness en el flujo normal intacto: el mismo plan vigente otra vez -> rc 16" "$_s1:$(_ep_run)" "0:16"
_ep_reset; { _ep_user "presenta"; _ep_exit "$PA" toolu_1; _ep_rej toolu_1; } > "$T/recs.sessA"; EP_STATUS=waiting; EP_BUSY=0; _mkscreen "$PB" > "$T/screen"
ok "dev busy + waiting -> rc 10 antes de leer nada" "$(_ep_run):$(_ep_lines "$T/cap.log"):$(_ep_lines "$T/rec.log")" "10:0:0"

echo "-- F. garantías estáticas --"
NUEVAS="$(declare -f tco_plan_dialog_head_from _tco_plan_norm _tco_plan_sha _tco_plan_ledger_equal _tco_plan_block_is_last _tco_plan_tail_is_chrome)"
ok "el código nuevo no teclea (ningún send-keys)" "$(printf '%s\n' "$NUEVAS" | grep -c 'send-keys')" 0
ok "la clase: tco_plan_from_transcript sigue en 2 líneas (definición y único consumidor)" "$(grep -rn 'tco_plan_from_transcript' "$SC" | wc -l | tr -d ' ')" 2
ok "el código nuevo no lee el .md del plan (sin planFilePath ni rutas de plans)" "$(printf '%s\n' "$NUEVAS" | grep -cE 'planFilePath|plans/')" 0
ok "rc 21 con una sola salida en extract-plan.sh" "$(grep -c 'return 21' "$SC/extract-plan.sh")" 1
ok "la escalera de scrollback sigue siendo 2000/4000/8000" "$(grep -c 'for SB in 2000 4000 8000' "$SC/extract-plan.sh")" 1
ok "la sub-suite ejecutó TOTAL_ESPERADO aserciones (esta incluida)" "$((PASS+FAIL+1))" "$TOTAL_ESPERADO"

printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] && [ "$((PASS+FAIL))" -eq "$TOTAL_ESPERADO" ]
