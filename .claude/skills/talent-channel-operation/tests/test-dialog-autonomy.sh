#!/usr/bin/env bash
# Autonomía con transportes dobles y selector real; ejecutar solo en el arnés.
# shellcheck disable=SC2329,SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/../scripts"
# shellcheck source=/dev/null
. "$HERE/capturas-codificadas.sh"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
AWK_BIN="${TCO_TEST_AWK:-awk}"
command -v "$AWK_BIN" >/dev/null || { printf 'FAIL falta %s\n' "$AWK_BIN"; exit 1; }
awk() { command "$AWK_BIN" "$@"; }
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "${TCO_AUTONOMY_LIB:-$SC/lib.sh}"
declare -A _TCO_PENDING_TEXT=()
REAL="$HERE/fixtures/pane/claude_2.1.289"
TMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}
confirm_capture() {
  local destination=Xhigh
  [ "${confirm_title:-Change effort level?}" != 'Change model?' ] || destination="Opus $(tco_modelo_version_visible "$MODEL_OPUS")"
  printf '──────────────────────────────\n%s\nSwitching means full history gets re-read\n❯ 1. Yes, switch to %s\n  2. No\nEnter to confirm · Esc to cancel\n' "${confirm_title:-Change effort level?}" "$destination"
}
trust_capture() {
  printf 'Do you trust this folder?\n❯ 1. Yes, I trust this folder\n  2. No\nEnter to confirm · Esc to cancel\n'
}
picker() {
  case "$(cat "$TMP_TEST/active")" in
    opus) sed 's/Sonnet ✔/Sonnet/; s/4\. Opus /4. Opus ✔ /' "$REAL/modal.txt" ;;
    *) cat "$REAL/modal.txt" ;;
  esac
}
capture() {
  case "$(cat "$TMP_TEST/state")" in
    picker) picker ;;
    confirm) confirm_capture ;;
    trust) trust_capture ;;
    other) trust_capture ;;
    incomplete) picker | sed '/Enter to set/d' ;;
    quoted) picker; cat "$REAL/idle.txt" ;;
    echo) sed "s|^❯.*|❯ $(cat "$TMP_TEST/text")|" "$REAL/idle.txt" ;;
    ready)
      [ "${wrong_effect:-no}" != yes ] || printf 'Kept model as Sonnet 5.5\n'
      sed "s|bypass permissions|● ${effort_display:-Xhigh} /effort · bypass permissions|" "$REAL/idle.txt"
      [ "${other_after_effect:-no}" != yes ] || trust_capture ;;
    codex) printf 'OpenAI Codex\n> \n' ;;
    *) cat "$REAL/idle.txt" ;;
  esac
}
tmux() {
  local key="${*: -1}"
  if [[ "$*" == *' -l -- '* ]]; then
    printf '%s' "$key" > "$TMP_TEST/text"
    printf 'texto:%s\n' "$key" >> "$TMP_TEST/keys"
    printf echo > "$TMP_TEST/state"
    return
  fi
  printf '%s\n' "$key" >> "$TMP_TEST/keys"
  case "$key" in
    C-m|Enter)
      case "$(cat "$TMP_TEST/state")" in
        echo)
          case "$(cat "$TMP_TEST/text")" in
            /model) printf '%s' "${opening:-picker}" > "$TMP_TEST/state" ;;
            /effort*) if [ "${confirmation:-no}" = yes ]; then printf confirm > "$TMP_TEST/state"; else printf ready > "$TMP_TEST/state"; fi ;;
            *) printf idle > "$TMP_TEST/state" ;;
          esac ;;
        confirm) [ "${wrong_effect:-no}" = yes ] || printf '%s' "${target:-opus}" > "$TMP_TEST/active"; printf ready > "$TMP_TEST/state" ;;
        trust) printf codex > "$TMP_TEST/state" ;;
      esac ;;
    4|2)
      target=opus; [ "$key" = 4 ] || target=sonnet
      printf '%s' "$target" > "$TMP_TEST/target"
      if [ "${confirmation:-no}" = yes ]; then printf confirm > "$TMP_TEST/state"
      else [ "${wrong_effect:-no}" = yes ] || printf '%s' "$target" > "$TMP_TEST/active"; printf ready > "$TMP_TEST/state"; fi ;;
    Escape) printf ready > "$TMP_TEST/state" ;;
    C-u) printf idle > "$TMP_TEST/state" ;;
  esac
}
incus() {
  local command="${8:-}"
  [[ "$command" == 'tmux send-keys '* ]] || return 0
  if [[ "$command" == *' -l -- '* ]]; then tmux send-keys -l -- "${*: -1}"
  else
    local -a words; local key
    read -r -a words <<< "$command"
    for key in "${words[@]:4}"; do tmux send-keys "$key"; done
  fi
}
tco_cap_pane() { capture; }
tco_cap_pane_e() { capture; }
tco_pane_busy() { return 1; }
_tco_pane_cli_version() { printf 'claude:2.1.289'; }
sleep() { :; }
reset() { printf idle > "$TMP_TEST/state"; printf sonnet > "$TMP_TEST/active"; : > "$TMP_TEST/keys"; : > "$TMP_TEST/text"; }
export TCO_MODELOS_REGISTRO="$HERE/fixtures/modelos-cli-current.conf"
MODEL_OPUS="$(tco_modelo_read plan)" || exit 1
MODEL_SONNET="$(tco_modelo_read coding)" || exit 1
export TCO_DIALOG_EFFECT_POLLS=2 TCO_EFFORT_CONFIRM_MAX=2 TCO_RELAY_ECHO_GAP=0
model_case() (
  local name="$1" requested="$2" opening="$3" confirmation="$4" wrong_effect="${5:-no}" rc=0 target=opus
  local confirm_title='Change model?'
  reset
  tco_set_model 01 v:.0 "$requested" > "$TMP_TEST/result" 2>&1 || rc=$?
  printf 'REGISTRO %s rc=%s: %s\n' "$name" "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" >&2
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)
ok 'modelo distinto autónomo por selector real' "$(model_case distinto "$MODEL_OPUS" picker no)" '0:texto:/model,C-m,4,texto:/model,C-m,Escape'
ok 'modelo distinto con confirmación autónoma' "$(model_case confirmado "$MODEL_OPUS" picker yes)" '0:texto:/model,C-m,4,1,C-m,texto:/model,C-m,Escape'
ok 'modelo activo sin dígito' "$(model_case activo "$MODEL_SONNET" picker no)" '0:texto:/model,C-m,Escape'
ok 'selector ausente sin dígito' "$(model_case ausente "$MODEL_OPUS" idle no)" '2:texto:/model,C-m'
ok 'otro diálogo sin navegación' "$(model_case otro "$MODEL_OPUS" other no)" '2:texto:/model,C-m'
ok 'selector incompleto sin navegación' "$(model_case incompleto "$MODEL_OPUS" incomplete no)" '2:texto:/model,C-m'
ok 'selector citado con compositor no navega' "$(model_case citado "$MODEL_OPUS" quoted no)" '2:texto:/model,C-m'
ok 'modelo distinto tras Kept falla sin reintento' "$(model_case kept "$MODEL_OPUS" picker no yes)" '2:texto:/model,C-m,4,texto:/model,C-m,Escape'
for confirmation in no yes; do
  actual="$(
    reset; rc=0
    tco_set_effort 01 v:.0 xhigh >/dev/null 2>&1 || rc=$?
    printf 'REGISTRO esfuerzo-%s rc=%s: %s\n' "$confirmation" "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" >&2
    printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
  )"
  expected='0:texto:/effort xhigh,C-m'
  [ "$confirmation" = no ] || expected="$expected,1,C-m"
  ok "esfuerzo autónomo confirmación=$confirmation" "$actual" "$expected"
done
ok 'plan y código aseguran modelo sin intervención' "$(
  reset; confirmation=no; rc=0
  tco_ensure_model 01 v:.0 "$MODEL_OPUS" >/dev/null 2>&1 || rc=$?
  tco_ensure_model 01 v:.0 "$MODEL_SONNET" >/dev/null 2>&1 || rc=$?
  printf 'REGISTRO plan-código rc=%s: %s\n' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" >&2
  printf '%s:%s' "$rc" "$(cat "$TMP_TEST/active")"
)" 0:sonnet
ok 'confianza de carpeta autónoma con efecto' "$(
  reset; printf trust > "$TMP_TEST/state"; rc=0
  tco_send_dialog_choice 01 v:.0 trust 1 yes >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '0:1,C-m'
for state in idle echo quoted other; do
  ok "submit Claude conserva propiedad en $state" "$(
    reset; printf '%s' "$state" > "$TMP_TEST/state"; printf 'texto propio' > "$TMP_TEST/text"; rc=0
    tco_send_submit 01 v:.0 --expected 'texto propio' C-m >/dev/null 2>&1 || rc=$?
    printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
  )" "$(case "$state" in idle|quoted) printf '0:' ;; echo) printf '0:C-m' ;; *) printf '2:' ;; esac)"
done
ok 'submit ajeno no pulsa envío' "$(
  reset; printf echo > "$TMP_TEST/state"; printf ajeno > "$TMP_TEST/text"; rc=0
  tco_send_submit 01 v:.0 --expected propio C-m >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:'
ok 'otro CLI conserva dos Enter históricos' "$(
  reset; _tco_pane_cli_version() { printf 'codex:1'; }; TCO_AUDIT_CLI=codex; rc=0
  tco_send_submit 01 v:.0 >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '0:Enter,Enter'
for cleaner in tco_clear_input tco_deep_clear_input; do
  for content in propio ajeno; do
    ok "$cleaner borra solo eco propio $content" "$(
      reset; printf echo > "$TMP_TEST/state"; printf '%s' "$content" > "$TMP_TEST/text"; _TCO_PENDING_TEXT[01:v:.0]=propio; rc=0
      "$cleaner" 01 v:.0 >/dev/null 2>&1 || rc=$?
      printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
    )" "$(if [ "$content" = propio ]; then printf '0:C-a,C-k,C-u'; else printf '2:'; fi)"
  done
done
for capture_kind in model confirm trust; do
  ok "opción ausente de $capture_kind no teclea" "$(
    reset; printf '%s' "$capture_kind" > "$TMP_TEST/state"; [ "$capture_kind" != model ] || printf picker > "$TMP_TEST/state"; rc=0
    tco_send_dialog_choice 01 v:.0 "$capture_kind" 9 yes xhigh >/dev/null 2>&1 || rc=$?
    printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
  )" '2:'
done
ok 'otro diálogo preexistente devuelve dos sin ninguna tecla' "$(
  reset; printf other > "$TMP_TEST/state"; rc=0
  tco_set_model 01 v:.0 "$MODEL_OPUS" >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:'
ok 'opción ausente del selector acreditado no teclea' "$(
  reset; printf picker > "$TMP_TEST/state"; rc=0
  tco_send_dialog_choice 01 v:.0 model 9 no "$MODEL_OPUS" >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:'
ok 'diálogo citado tras texto no autoriza navegación' "$(
  reset; printf quoted > "$TMP_TEST/state"; rc=0
  tco_send_dialog_choice 01 v:.0 model 4 no "$MODEL_OPUS" >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:'
for locale in C C.UTF-8; do
  ok "selector y opción real en $locale" "$(LC_ALL="$locale" tco_dialog_choice_from model 4 < "$REAL/modal.txt"; echo $?)" 0
  ok "selector sin pie no navega en $locale" "$(sed '/Enter to set/d' "$REAL/modal.txt" | LC_ALL="$locale" tco_dialog_choice_from model 4; echo $?)" 1
done
ok 'submit pierde identidad de CLI y no pulsa tecla' "$(
  reset; _tco_pane_cli_version() { return 1; }; rc=0
  tco_send_submit 01 v:.0 >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:'
ok 'lista inválida se rechaza antes de cualquier tecla' "$(
  reset; _tco_pane_cli_version() { printf 'codex:1'; }; rc=0
  tco_send_submit 01 v:.0 Enter arbitrary >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:'
ok 'submit Claude no duplica segundo Enter si ya consumió el texto' "$(
  reset; printf echo > "$TMP_TEST/state"; printf propio > "$TMP_TEST/text"; rc=0
  tco_send_submit 01 v:.0 --expected propio Enter Enter >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '0:Enter'
for cleaner in tco_clear_input tco_deep_clear_input; do
  for content in duplicate unknown ghost; do
    ok "$cleaner conserva $content sin teclas" "$(
      reset; _TCO_PENDING_TEXT[01:v:.0]=propio; rc=0
      tco_cap_pane_e() {
        case "$content" in
          duplicate) sed 's/^❯.*/❯ propio propio/' "$REAL/idle.txt" ;;
          unknown) cat "$REAL/redraw.txt" ;;
          ghost) sed $'s/^❯.*/❯ \033[2mpropio\033[0m/' "$REAL/idle.txt" ;;
        esac
      }
      "$cleaner" 01 v:.0 >/dev/null 2>&1 || rc=$?
      printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
    )" "$(if [ "$content" = ghost ]; then printf '0:'; else printf '2:'; fi)"
  done
done
ok 'texto propio registrado por la primitiva permite limpieza del envío fallido' "$(
  reset; rc=0
  tmux() {
    if [[ "$*" == *' -l -- '* ]]; then printf '%s' "${*: -1}" > "$TMP_TEST/text"; printf echo > "$TMP_TEST/state";
    elif [ "${*: -1}" = C-m ]; then return 1;
    else printf idle > "$TMP_TEST/state"; fi
  }
  _tco_send_text_submit 01 v:.0 propio >/dev/null 2>&1 || rc=$?
  tco_clear_input 01 v:.0 >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(cat "$TMP_TEST/state")"
)" '1:idle'
for state in idle quoted; do
  ok "Escape no se envía por prosa o reposo $state" "$(
    reset; printf '%s' "$state" > "$TMP_TEST/state"; rc=0
    tco_escape_stuck_input 01 v:.0 >/dev/null 2>&1 || rc=$?
    printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
  )" '2:'
done
ok 'esfuerzo sin efecto tras confirmar no repite teclas' "$(
  reset; confirmation=yes; effort_display=High; rc=0
  tco_set_effort 01 v:.0 xhigh >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:texto:/effort xhigh,C-m,1,C-m'
ok 'captura fallida no navega aunque imprima selector' "$(
  reset; tco_cap_pane() { picker; return 1; }; rc=0
  tco_send_dialog_choice 01 v:.0 model 4 no "$MODEL_OPUS" >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:'
ok 'confianza con diálogo persistente no repite teclas' "$(
  reset; printf trust > "$TMP_TEST/state"; rc=0
  tmux() { printf '%s\n' "${*: -1}" >> "$TMP_TEST/keys"; }
  tco_send_dialog_choice 01 v:.0 trust 1 yes >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:1,C-m'
ok 'fila duplicada se rechaza por estructura' "$(
  { cat "$REAL/modal.txt" | sed '/4\. Opus /p'; } | tco_dialog_choice_from model 4; echo $?
)" 1
ok 'Escape de pegado se acredita en el compositor actual' "$(
  reset; tco_cap_pane() { sed 's/^❯.*/❯ [Pasted Content #1]/' "$REAL/idle.txt"; }; rc=0
  tco_escape_stuck_input 01 v:.0 >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '0:Escape'
ok 'Claude bajo intérprete sigue rechazando texto ajeno' "$(
  reset; printf echo > "$TMP_TEST/state"; printf ajeno > "$TMP_TEST/text"; rc=0
  _tco_pane_cli_version() { printf 'node:1'; }
  _tco_pane_agent_exes() { printf claude; }
  TCO_DEV_CLI=claude; TCO_AUDIT_CLI=codex
  tco_send_submit 01 v:.0 --expected propio C-m >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:'
ok 'otro proveedor bajo intérprete conserva teclas históricas' "$(
  reset; rc=0
  _tco_pane_cli_version() { printf 'node:1'; }
  _tco_pane_agent_exes() { [ "$3" = codex ] && printf codex; }
  TCO_DEV_CLI=claude; TCO_AUDIT_CLI=codex
  tco_send_submit 01 v:.0 >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '0:Enter,Enter'
ok 'recibo del relay cruza subshell y permite reenvío propio del auditor' "$(
  reset; rc=0
  tco_wait_idle() { return 0; }
  tco_delivery_baseline() { return 1; }
  tco_verify_delivered() { return 0; }
  tco_relay_file 01 v:.0 "$REAL/idle.txt" rol mensaje 1 '' "$TMP_TEST/pending" >/dev/null 2>&1 || rc=$?
  cat "$TMP_TEST/pending" > "$TMP_TEST/text"; printf echo > "$TMP_TEST/state"
  tco_send_submit 01 v:.0 --expected "$(cat "$TMP_TEST/pending")" C-m >/dev/null 2>&1 || rc=$?
  printf '%s:%s:%s' "$rc" "${_TCO_PENDING_TEXT[01:v:.0]:-ausente}" "$(grep -c '^C-m$' "$TMP_TEST/keys")"
)" '0:ausente:2'
ok 'aviso activo tras confirmar esfuerzo no acredita una barra antigua' "$(
  reset; confirmation=yes; other_after_effect=yes; rc=0
  tco_set_effort 01 v:.0 xhigh >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:texto:/effort xhigh,C-m,1,C-m'
for operation in model effort; do
  ok "confirmación cruzada rechazada para $operation" "$(
    reset; confirmation=yes; rc=0
    if [ "$operation" = effort ]; then
      confirm_title='Change model?'
      tco_set_effort 01 v:.0 xhigh >/dev/null 2>&1 || rc=$?
    else
      confirm_title='Change effort level?'
      tco_set_model 01 v:.0 "$MODEL_OPUS" >/dev/null 2>&1 || rc=$?
    fi
    printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
  )" "$(if [ "$operation" = effort ]; then printf '2:texto:/effort xhigh,C-m'; else printf '2:texto:/model,C-m,4'; fi)"
  for form in incomplete quoted; do
    ok "confirmación $operation $form no navega" "$(
      reset; rc=0; expected=xhigh; confirm_title='Change effort level?'
      if [ "$operation" = model ]; then expected="$MODEL_OPUS"; confirm_title='Change model?'; fi
      tco_cap_pane() {
        if [ "$form" = incomplete ]; then confirm_capture | sed '/2\. No/d'
        else confirm_capture; cat "$REAL/idle.txt"; fi
      }
      tco_send_dialog_choice 01 v:.0 confirm 1 yes "$expected" >/dev/null 2>&1 || rc=$?
      printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
    )" '2:'
  done
done
for after_digit in ready cursor foreign unknown other changed wrong; do
  ok "captura antes de envío con confirmación $after_digit" "$(
    reset; printf confirm > "$TMP_TEST/state"; rc=0
    tmux() {
      local key="${*: -1}"
      printf '%s\n' "$key" >> "$TMP_TEST/keys"
      if [ "$key" = 1 ]; then printf '%s' "$after_digit" > "$TMP_TEST/state"; fi
      if [ "$key" = C-m ] && [ "$after_digit" = cursor ]; then printf ready > "$TMP_TEST/state"; fi
    }
    tco_cap_pane() {
      case "$(cat "$TMP_TEST/state")" in
        confirm)
          if [ "$after_digit" = cursor ]; then confirm_capture | sed 's/^❯ 1/  1/; s/^  2/❯ 2/'
          else confirm_capture; fi ;;
        cursor) confirm_capture ;;
        foreign) sed 's/^❯.*/❯ mensaje ajeno/' "$REAL/idle.txt" ;;
        unknown) cat "$REAL/redraw.txt" ;;
        other) trust_capture ;;
        changed) confirm_capture | sed 's/1. Yes/1. Otra opción/' ;;
        wrong) cat "$REAL/idle.txt" ;;
        *) capture ;;
      esac
    }
    tco_send_dialog_choice 01 v:.0 confirm 1 yes xhigh >/dev/null 2>&1 || rc=$?
    printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
  )" "$(case "$after_digit" in ready) printf '0:1' ;; cursor) printf '0:1,C-m' ;; *) printf '2:1' ;; esac)"
done
for scenario in busy-first race race-deferred deferred cycles foreign unknown exhausted unconfirmed; do
  ok "relevo GO autónomo $scenario" "$(
    reset; rc=0; export TCO_QUEUE_DIR="$TMP_TEST/queue-$scenario" TCO_GO_WAIT_MAX=0 TCO_GO_POLL_GAP=0 TCO_GO_RETRIES=2 TCO_GO_RETRY_GAP=0
    printf 0 > "$TMP_TEST/go-polls"
    tco_pane_busy() {
      local n; n="$(cat "$TMP_TEST/go-polls")"; printf '%s' "$((n+1))" > "$TMP_TEST/go-polls"
      case "$scenario" in
        busy-first) [ "$n" -gt 0 ] && return 1; return 0 ;;
        race|race-deferred) { [ "$n" -eq 0 ] || [ "$n" -ge 3 ]; } && return 1; return 0 ;;
        cycles) [ "$n" -gt 0 ] && return 1; return 0 ;;
        deferred|exhausted) return 0 ;;
        unknown) return 2 ;;
        *) return 1 ;;
      esac
    }
    tco_verify_delivered() { [ "$scenario" != unconfirmed ]; }
    [ "$scenario" != foreign ] || { printf echo > "$TMP_TEST/state"; printf ajeno > "$TMP_TEST/text"; }
    [ "$scenario" != busy-first ] || TCO_GO_WAIT_MAX=2
    [ "$scenario" != race ] || TCO_GO_WAIT_MAX=2
    if [ "$scenario" = cycles ]; then
      tco_queue_dev_file_cycles 01 v:.0 "$REAL/idle.txt" plan-go >/dev/null 2>&1 || rc=$?
    else
      tco_queue_dev_file 01 v:.0 "$REAL/idle.txt" plan-go >/dev/null 2>&1 || rc=$?
    fi
    if [ "$scenario" = deferred ] || [ "$scenario" = race-deferred ]; then
      printf 'primer=%s:' "$rc"
      tco_pane_busy() { return 1; }; rc=0
      tco_queue_dev_file 01 v:.0 "$REAL/idle.txt" plan-go >/dev/null 2>&1 || rc=$?
    fi
    if [ "$scenario" = exhausted ]; then
      tco_queue_dev_file 01 v:.0 "$REAL/idle.txt" plan-go >/dev/null 2>&1 || rc=$?
      tco_queue_dev_file 01 v:.0 "$REAL/idle.txt" plan-go >/dev/null 2>&1 || rc=$?
    fi
    if [ "$rc" -eq 0 ] || [ "$scenario" = unconfirmed ]; then
      tco_queue_dev_file 01 v:.0 "$REAL/idle.txt" plan-go >/dev/null 2>&1 || rc=$?
    fi
    printf 'REGISTRO GO-%s rc=%s: %s\n' "$scenario" "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" >&2
    printf '%s:%s:%s' "$rc" "$(grep -c '^texto:' "$TMP_TEST/keys")" "$(grep -c '^C-m$' "$TMP_TEST/keys")"
    if [ "$scenario" = deferred ] || [ "$scenario" = race-deferred ]; then
      printf ':%s' "$(find "$TCO_QUEUE_DIR" -name literal -type f | wc -l | tr -d ' ')"
    fi
  )" "$(case "$scenario" in busy-first|race|cycles) printf 0:1:1 ;; deferred|race-deferred) printf primer=3:0:1:1:1 ;; unconfirmed) printf 2:1:1 ;; *) printf 2:0:0 ;; esac)"
done
for content in propio ajeno; do
  ok "aborto preserva compositor $content y solo interrumpe" "$(
    reset; printf echo > "$TMP_TEST/state"; printf '%s' "$content" > "$TMP_TEST/text"; rc=0
    tco_wait_idle() { return 0; }
    incus() { printf '%s\n' "${8:-}" >> "$TMP_TEST/keys"; }
    tco_abort_dev_dispatch 01 v:.0 'fallo sintético' >/dev/null 2>&1 || rc=$?
    printf '%s:%s:%s' "$rc" "$(grep -c ' C-u' "$TMP_TEST/keys")" "$(cat "$TMP_TEST/text")"
  )" "0:0:$content"
done
ok 'brief inicial en reposo entregado una vez' "$(
  reset; rc=0
  tco_wait_idle() { return 0; }
  tco_delivery_baseline() { : > "$4"; }
  tco_verify_delivered() { return 0; }
  tco_send_dev 01 v:.0 'brief inicial' >/dev/null 2>&1 || rc=$?
  printf 'REGISTRO brief rc=%s: %s\n' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" >&2
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '0:texto:brief inicial,C-m'
for kind in survey survey-rating; do
  ok "curación autónoma de $kind" "$(
    reset; rc=0
    tco_cap_pane() {
      if [ "$kind" = survey ]; then printf 'Can Anthropic look at your session transcript?\n  y: Yes  n: No  d: Details\n'
      else cat "$HERE/fixtures/cli-current/survey-rating.txt"; fi
    }
    tco_pane_heal 01 v:.0 "$kind" >/dev/null 2>&1 || rc=$?
    printf 'REGISTRO curación-%s rc=%s: %s\n' "$kind" "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" >&2
    printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
  )" "$(if [ "$kind" = survey ]; then printf 0:n; else printf 0:0; fi)"
done
for title in 'Change model?' 'Change effort level?' 'Do you trust this folder?' 'Bypass Permissions mode' 'Choose a new constellation?'; do
  for position in active historical; do
    ok "diálogo $title en posición $position conserva propiedad" "$(
      reset; rc=0
      tco_cap_pane_e() {
        [ "$position" != active ] || cat "$REAL/idle.txt"
        printf '\n%s\n❯ 1. Yes\n  2. No\nEnter to confirm · Esc to cancel\n' "$title"
        [ "$position" != historical ] || capture
      }
      tco_cap_pane() { tco_cap_pane_e; }
      _tco_send_text_submit 01 v:.0 continuemos >/dev/null 2>&1 || rc=$?
      printf '%s:%s:%s' "$rc" "$(grep -c '^texto:' "$TMP_TEST/keys")" "$(grep -c '^C-m$' "$TMP_TEST/keys")"
    )" "$(if [ "$position" = active ]; then printf 2:0:0; else printf 0:1:1; fi)"
  done
done
for structure in cursor ascii-cursor confirm cancel select set; do
  ok "bloque estructural $structure niega texto sin título conocido" "$(
    reset; rc=0
    tco_cap_pane_e() {
      cat "$REAL/idle.txt"
      case "$structure" in
        cursor) printf '\n❯ 7. Destino\n' ;;
        ascii-cursor) printf '\n> 7. Destino\n' ;;
        select) printf '\nUse arrows · Enter to select · Esc to cancel\n' ;;
        *) printf '\nEnter to %s\n' "$structure"; [ "$structure" != cancel ] || printf 'Esc to cancel\n' ;;
      esac
    }
    tco_cap_pane() { tco_cap_pane_e; }
    _tco_send_text_submit 01 v:.0 continuemos >/dev/null 2>&1 || rc=$?
    printf '%s:%s:%s' "$rc" "$(grep -c '^texto:' "$TMP_TEST/keys")" "$(grep -c '^C-m$' "$TMP_TEST/keys")"
  )" '2:0:0'
done
for notice in hint weekly; do
  ok "pie benigno $notice permite envío normal" "$(
    reset; rc=0
    tco_cap_pane_e() {
      capture
      if [ "$notice" = hint ]; then printf '\n? for shortcuts\n'
      else printf '\nWeekly limit reached · resets tomorrow\n'; fi
    }
    tco_cap_pane() { tco_cap_pane_e; }
    _tco_send_text_submit 01 v:.0 continuemos >/dev/null 2>&1 || rc=$?
    printf '%s:%s:%s' "$rc" "$(grep -c '^texto:' "$TMP_TEST/keys")" "$(grep -c '^C-m$' "$TMP_TEST/keys")"
  )" '0:1:1'
done
for race in replaced renumbered duplicated stable; do
  ok "destino del selector en recaptura $race" "$(
    reset; rc=0; confirmation=no; printf 0 > "$TMP_TEST/picker-captures"
    tco_cap_pane() {
      local n
      if [ "$(cat "$TMP_TEST/state")" != picker ]; then capture; return; fi
      n="$(cat "$TMP_TEST/picker-captures")"
      printf '%s' "$((n+1))" > "$TMP_TEST/picker-captures"
      if [ "$n" -eq 0 ]; then picker; return; fi
      case "$race" in
        replaced) picker | sed 's/4\. Opus /4. Haiku /; s/Opus 5\.5/Haiku 4.5/g' ;;
        renumbered) picker | sed 's/4\. Opus /5. Opus /; s/5\. Haiku /4. Haiku /' ;;
        duplicated) picker | sed 's/5\. Haiku /5. Opus /; s/Haiku 4\.5/Opus 5.5/g' ;;
        stable) picker ;;
      esac
    }
    tco_set_model 01 v:.0 "$MODEL_OPUS" >/dev/null 2>&1 || rc=$?
    printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
  )" "$(if [ "$race" = stable ]; then printf '0:texto:/model,C-m,4,texto:/model,C-m,Escape'; else printf '2:texto:/model,C-m'; fi)"
done

# Secuencias reales: cada transición la causa una tecla del doble de transporte.
DIALOGS="$REAL/model-dialogs"
real_sequence() (
  local scenario="$1" suffix="$2" rc=0 target="$MODEL_OPUS"
  local state=idle operation=model before=d-06-tras-elegir-sonnet after=d-02-tras-aceptar-switch
  reset
  unset TCO_MODEL_PICKER_ALIASES
  case "$scenario" in
    sonnet) target="$MODEL_SONNET"; before=d-02-tras-aceptar-switch; after=d-06-tras-elegir-sonnet ;;
    active) before=d-02-tras-aceptar-switch ;;
    xhigh|high) operation=effort; target="$scenario"; after=d-04-effort-xhigh-tras-enter
      [ "$scenario" != high ] || after=d-07-effort-high-tras-enter ;;
  esac
  tmux() {
    local key="${*: -1}"
    if [[ "$*" == *' -l -- '* ]]; then
      printf 'texto:%s\n' "$key" >> "$TMP_TEST/keys"; state=typed; return
    fi
    printf '%s\n' "$key" >> "$TMP_TEST/keys"
    case "$state:$key" in
      typed:C-m) if [ "$operation" = model ]; then state=picker; else state=applied; fi ;;
      picker:4) state=confirm ;;
      picker:2|confirm:1) state=applied ;;
      picker:Escape) state=idle ;;
      *) return 1 ;;
    esac
    printf '%s' "$state" > "$TMP_TEST/state"
  }
  # El estado se guarda en disco: las capturas corren en subshells.
  incus() {
    state="$(cat "$TMP_TEST/state")"
    local command="${8:-}" key
    [[ "$command" == 'tmux send-keys '* ]] || return 0
    if [[ "$command" == *' -l -- '* ]]; then tmux send-keys -l -- "${*: -1}"
    else key="${command##* }"; tmux send-keys "$key"; fi
    printf '%s' "$state" > "$TMP_TEST/state"
  }
  tco_cap_pane_e() {
    case "$(cat "$TMP_TEST/state")" in
      idle) tco_fixture_decode "$DIALOGS/$before$suffix.txt" ;;
      typed)
        if [ "$operation" = model ]; then tco_fixture_decode "$REAL/slash/s-slash-model$suffix.txt"
        elif [ "$target" = xhigh ]; then tco_fixture_decode "$DIALOGS/d-03-effort-xhigh-tecleado$suffix.txt"
        else tco_fixture_decode "$DIALOGS/$before$suffix.txt" | sed 's/❯ /❯ \/effort high/'; fi ;;
      picker)
        if [ "$scenario" = opus ]; then cat "$REAL/modal.txt"
        else tco_fixture_decode "$DIALOGS/d-05-selector-con-opus-activo$suffix.txt"; fi ;;
      confirm) tco_fixture_decode "$DIALOGS/d-01-switch-model-con-historial$suffix.txt" ;;
      applied) tco_fixture_decode "$DIALOGS/$after$suffix.txt" ;;
    esac
  }
  tco_cap_pane() { tco_cap_pane_e | tco_strip_ansi_from; }
  if [ "$operation" = model ]; then tco_set_model 01 v:.0 "$target" > "$TMP_TEST/result" 2>&1 || rc=$?
  else tco_set_effort 01 v:.0 "$target" > "$TMP_TEST/result" 2>&1 || rc=$?; fi
  cat "$TMP_TEST/result" >&2
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)
  for suffix in '' .ansi; do
    for scenario in opus sonnet active xhigh high; do
      case "$scenario" in
        opus) expected='0:texto:/model,C-m,4,1' ;;
        sonnet) expected='0:texto:/model,C-m,2' ;;
        active) expected='0:texto:/model,C-m,Escape' ;;
        *) expected="0:texto:/effort $scenario,C-m" ;;
      esac
      ok "flujo real $scenario $suffix $AWK_BIN teclas exactas" "$(real_sequence "$scenario" "$suffix")" "$expected"
    done
    for variant in wrong duplicate missing-negative inverted unknown; do
      ok "Switch model $variant $suffix $AWK_BIN sin teclas" "$(
        reset; rc=0
        tco_cap_pane() {
          tco_fixture_decode "$DIALOGS/d-01-switch-model-con-historial$suffix.txt" | tco_strip_ansi_from |
            case "$variant" in
              wrong) sed 's/Yes, switch to Opus 5.5/Yes, switch to Sonnet 5.5/' ;;
              duplicate) sed '/2\. No/c\    2. Yes, switch to Opus 5.5' ;;
              missing-negative) sed '/2\. No/d' ;;
              inverted) sed 's/1\. Yes, switch to Opus 5.5/1. No, go back/; s/2\. No, go back/2. Yes, switch to Opus 5.5/' ;;
              unknown) sed 's/Yes, switch to Opus 5.5/Continuar/' ;;
            esac
        }
        tco_send_dialog_choice 01 v:.0 confirm 1 yes "$MODEL_OPUS" > "$TMP_TEST/result" 2>&1 || rc=$?
        printf '%s:%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" "$(grep -c 'Switch model?' "$TMP_TEST/result")"
      )" '2::1'
    done
    for kind in model effort; do
      case "$kind" in model) fixture=d-02-tras-aceptar-switch; target="$MODEL_OPUS";; effort) fixture=d-04-effort-xhigh-tras-enter; target=xhigh;; esac
      for evidence in receipt status; do
        ok "efecto real $kind solo $evidence $suffix $AWK_BIN" "$(
          rc=0
          tco_fixture_decode "$DIALOGS/$fixture$suffix.txt" | tco_strip_ansi_from |
            if [ "$evidence" = receipt ]; then sed '/\[Opus 5.5\]/c\  Estado'; else sed '/⎿  Set /d'; fi |
            tco_dialog_meaning_from "effect-$kind" 0 "$target" || rc=$?
          printf '%s' "$rc"
        )" 0
      done
    done
    for kind in model effort; do
      case "$kind" in model) fixture=d-06-tras-elegir-sonnet; target="$MODEL_OPUS";; effort) fixture=d-07-effort-high-tras-enter; target=xhigh;; esac
      ok "recibo histórico $kind no acredita efecto $suffix $AWK_BIN" "$(
        rc=0
        tco_fixture_decode "$DIALOGS/$fixture$suffix.txt" | tco_dialog_meaning_from "effect-$kind" 0 "$target" || rc=$?
        printf '%s' "$rc"
      )" 1
    done
    ok "título libre conserva significado $suffix $AWK_BIN" "$(
      rc=0
      tco_fixture_decode "$DIALOGS/d-01-switch-model-con-historial$suffix.txt" | tco_strip_ansi_from |
        sed 's/Switch model?/Confirmar selección/' | tco_dialog_meaning_from confirm-model 1 "$MODEL_OPUS" || rc=$?
      printf '%s' "$rc"
    )" 0
  done
for operation in model effort; do
  ok "diálogo antiguo $operation sin destino no acredita significado" "$(
    rc=0; expected=xhigh; legacy_title='Change effort level?'
    if [ "$operation" = model ]; then expected="$MODEL_OPUS"; legacy_title='Change model?'; fi
    printf '────────────────────────\n%s\n❯ 1. Yes\n  2. No\nEnter to confirm · Esc to cancel\n' "$legacy_title" |
      tco_dialog_meaning_from "confirm-$operation" 1 "$expected" || rc=$?
    printf '%s' "$rc"
  )" 1
  for visible_title in 'Change model?' 'Switch model?' 'Change effort level?' 'Confirmar selección'; do
    ok "afirmativa genérica $operation [$visible_title] incompatible sin teclas" "$(
      reset; rc=0; expected=xhigh
      [ "$operation" != model ] || expected="$MODEL_OPUS"
      tco_cap_pane() {
        [ "$visible_title" = 'Change effort level?' ] || printf '────────────────────────\n'
        printf '%s\n❯ 1. Yes\n  2. No\nEnter to confirm · Esc to cancel\n' "$visible_title"
      }
      tco_send_dialog_choice 01 v:.0 confirm 1 yes "$expected" > "$TMP_TEST/result" 2>&1 || rc=$?
      diagnostic=no
      if grep -Fq "[$visible_title]" "$TMP_TEST/result" && grep -q 'versión del CLI no es compatible.*2.1.289' "$TMP_TEST/result"; then diagnostic=si; fi
      printf '%s:%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" "$diagnostic"
    )" '2::si'
  done
done
ok 'esfuerzo nombrado distinto no pulsa afirmativa' "$(
  reset; rc=0
  tco_cap_pane() { confirm_capture | sed 's/switch to Xhigh/switch to High/'; }
  tco_send_dialog_choice 01 v:.0 confirm 1 yes xhigh >/dev/null 2>&1 || rc=$?
  printf '%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")"
)" '2:'
# El panel puede redibujarse sin que el transporte envíe ninguna tecla más.
transition_sequence() (
  local scenario="$1" suffix="$2" rc=0 count=0 state=confirm
  reset
  export TCO_DIALOG_CLASSIFY_POLLS=6 TCO_DIALOG_CLASSIFY_GAP=0
  printf 0 > "$TMP_TEST/captures"
  incus() {
    local key="${8##* }"
    printf '%s\n' "$key" >> "$TMP_TEST/keys"
    case "$key" in
      1) printf observing > "$TMP_TEST/state" ;;
      C-m) printf applied > "$TMP_TEST/state" ;;
      *) return 1 ;;
    esac
  }
  printf confirm > "$TMP_TEST/state"
  tco_cap_pane() {
    state="$(cat "$TMP_TEST/state")"
    if [ "$state" = confirm ]; then
      tco_fixture_decode "$DIALOGS/d-01-switch-model-con-historial$suffix.txt" | tco_strip_ansi_from; return
    fi
    if [ "$state" = applied ]; then
      tco_fixture_decode "$DIALOGS/d-02-tras-aceptar-switch$suffix.txt" | tco_strip_ansi_from; return
    fi
    count="$(cat "$TMP_TEST/captures")"; count=$((count+1))
    printf '%s' "$count" > "$TMP_TEST/captures"
    case "$scenario:$count" in
      redraw:1|exhausted:*) : ;;
      redraw:2) printf '────────────────────────────────────────────────────\n' ;;
      double:1|double:2|single:1|interrupted:1|interrupted:3)
        tco_fixture_decode "$DIALOGS/d-01-switch-model-con-historial$suffix.txt" | tco_strip_ansi_from ;;
      interrupted:2) : ;;
      changed:*|title:*|generic:*|other:*|anomaly:*)
        case "$scenario" in
          changed) tco_fixture_decode "$DIALOGS/d-01-switch-model-con-historial$suffix.txt" | tco_strip_ansi_from | sed 's/2. No, go back/2. No/' ;;
          title) tco_fixture_decode "$DIALOGS/d-01-switch-model-con-historial$suffix.txt" | tco_strip_ansi_from | sed 's/Switch model?/Confirmar selección/' ;;
          generic) tco_fixture_decode "$DIALOGS/d-01-switch-model-con-historial$suffix.txt" | tco_strip_ansi_from | sed 's/Yes, switch to Opus 5.5/Yes/' ;;
          other) trust_capture ;;
          anomaly) printf 'How is Claude doing this session?\n' ;;
        esac ;;
      *) tco_fixture_decode "$DIALOGS/d-02-tras-aceptar-switch$suffix.txt" | tco_strip_ansi_from ;;
    esac
  }
  tco_send_dialog_choice 01 v:.0 confirm 1 yes "$MODEL_OPUS" > "$TMP_TEST/result" 2>&1 || rc=$?
  printf '%s:%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" "$(cat "$TMP_TEST/captures")"
)
for suffix in '' .ansi; do
  for scenario in redraw double single exhausted changed title generic other anomaly interrupted; do
    case "$scenario" in
      redraw) expected='0:1:4' ;;
      double) expected='0:1,C-m:2' ;;
      single) expected='0:1:3' ;;
      interrupted) expected='0:1:5' ;;
      exhausted|generic) expected='2:1:6' ;;
      other|anomaly) expected='2:1:2' ;;
      *) expected='2:1:1' ;;
    esac
    ok "clasificación tras dígito $scenario $suffix $AWK_BIN" "$(transition_sequence "$scenario" "$suffix")" "$expected"
  done
done
# Fotogramas reales tras elegir: la transcripción no acredita otro diálogo.
real_transition_sequence() (
  local scenario="$1" rc=0 count=0 frame
  reset
  export TCO_DIALOG_CLASSIFY_POLLS=6 TCO_DIALOG_CLASSIFY_GAP=0
  printf 0 > "$TMP_TEST/captures"
  printf confirm > "$TMP_TEST/state"
  incus() {
    local key="${8##* }"
    printf '%s\n' "$key" >> "$TMP_TEST/keys"
    [ "$key" = 1 ] || return 1
    printf observing > "$TMP_TEST/state"
  }
  tco_cap_pane() {
    if [ "$(cat "$TMP_TEST/state")" = confirm ]; then
      cat "$DIALOGS/transicion-switch-f01.txt"; return
    fi
    count="$(cat "$TMP_TEST/captures")"; count=$((count+1))
    printf '%s' "$count" > "$TMP_TEST/captures"
    case "$scenario:$count" in
      anomaly-single:1|anomaly-double:1|anomaly-double:2)
        printf 'How is Claude doing this session?\n'; return ;;
      exhausted:*|real:1|real:2|quoted:1|quoted:2) frame=f05 ;;
      real:3|quoted:3|receipt:*|anomaly-single:*) frame=f26 ;;
      *) frame=f33 ;;
    esac
    if [ "$scenario" = quoted ] && [ "$frame" = f05 ]; then
      # Citas de un plan y del pie dentro de la transcripción.
      printf '  1. Leer el plan\n  2. Escribir el resultado\nEnter to confirm · Esc to cancel\n'
    fi
    cat "$DIALOGS/transicion-switch-$frame.txt"
  }
  tco_send_dialog_choice 01 v:.0 confirm 1 yes "$MODEL_OPUS" > "$TMP_TEST/result" 2>&1 || rc=$?
  printf '%s:%s:%s' "$rc" "$(paste -sd ',' "$TMP_TEST/keys")" "$(cat "$TMP_TEST/captures")"
)
for scenario in real quoted receipt exhausted anomaly-single anomaly-double; do
  case "$scenario" in
    real|quoted) expected='0:1:4' ;;
    receipt) expected='0:1:2' ;;
    exhausted) expected='2:1:6' ;;
    anomaly-single) expected='0:1:3' ;;
    anomaly-double) expected='2:1:2' ;;
  esac
  ok "fotogramas reales tras dígito $scenario $AWK_BIN" "$(real_transition_sequence "$scenario")" "$expected"
done
unset -f awk
printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$((PASS+FAIL))" -eq 173 ] || { printf 'ERROR: contador de autonomía distinto de 173\n' >&2; exit 1; }
[ "$FAIL" -eq 0 ]
