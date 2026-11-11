#!/usr/bin/env bash
# Contrato de diálogos activos y envío con compositor propio. Solo en el arnés.
# El aislamiento de estas regresiones (sin agentes reales ni credenciales del usuario) solo vale si el proceso se lanza con el
# entorno limpio desde fuera: el arnés del paquete (`tests/run-tests.sh`, la batería de F0 por `clean_environment()` de
# `fases.py`) o el envoltorio de mutantes. La invocación directa sin entorno limpio queda NO SOPORTADA / NO AISLADA.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$TEST_DIR/../scripts"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# Fallo cerrado ANTES de cargar nada (00-config.sh carga $SECRET_DIR/agents.conf): el arnés no fija SECRET_DIR ni HOST_HOME,
# los trae quien lo llama (tests/run-tests.sh o el envoltorio de mutantes). Si caen en el HOME real del usuario, si existe un
# agents.conf o si hay una variable con nombre de credencial en el entorno, la suite no corre. HOME se comprueba en el mundo
# de las regresiones del lanzador, no aquí.
_tco_cierra() { printf 'FAIL entorno del arnés: %s\n' "$1"; exit 1; }
[ -n "${SECRET_DIR:-}" ] || _tco_cierra 'SECRET_DIR vacía o sin definir'
[ -n "${HOST_HOME:-}" ] || _tco_cierra 'HOST_HOME vacía o sin definir'
_tco_hogar_real="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
[ -n "$_tco_hogar_real" ] || _tco_hogar_real="${HOME:-}"
[ -n "$_tco_hogar_real" ] || _tco_cierra 'HOME real no verificable'
_tco_hogar_real="$(realpath -m -- "$_tco_hogar_real")"
for _tco_v in SECRET_DIR HOST_HOME; do
  _tco_ruta="$(realpath -m -- "${!_tco_v}")"
  case "$_tco_ruta/" in "$_tco_hogar_real"/*) _tco_cierra "$_tco_v cae dentro del HOME real" ;; esac
done
[ ! -e "$SECRET_DIR/agents.conf" ] || _tco_cierra 'existe agents.conf en SECRET_DIR'
while IFS= read -r _tco_n; do
  case "$_tco_n" in
    SECRET_DIR) ;;
    *TOKEN*|*SECRET*|*PASSWORD*|*API_KEY*|*OAUTH*) _tco_cierra "variable de entorno con nombre de credencial: $_tco_n" ;;
  esac
done < <(compgen -e)
_TCO_ENTORNO_OK=1
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "$SC/lib.sh"
FX="$TEST_DIR/fixtures/cli-current"
REAL="$TEST_DIR/fixtures/pane/claude_2.1.289"
TMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}
ok 'arnés: SECRET_DIR y HOST_HOME fuera del HOME real, sin agents.conf y sin credenciales en el entorno' "$_TCO_ENTORNO_OK" 1
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
_dialog() {
  # Selector y valoración: capturas reales; restantes: controles sintéticos de la suite.
  case "$1" in
    model) cat "$REAL/modal.txt" ;;
    rating) cat "$FX/survey-rating.txt" ;;
    survey) printf 'Can Anthropic look at your session transcript?\n  y: Yes  n: No  d: Details\n' ;;
    trust) printf 'Do you trust this folder?\n❯ 1. Yes, I trust this folder\n  2. No\nEnter to confirm · Esc to cancel\n' ;;
    bypass) printf 'Bypass Permissions mode\n❯ 1. Accept risk and bypass\n  2. Cancel\nEnter to confirm · Esc to cancel\n' ;;
    queue) cat "$REAL/idle.txt"; printf '\nPress up to edit queued messages\n' ;;
  esac
}
for locale in C C.UTF-8; do
  for kind in model rating survey trust bypass queue; do
    case "$kind" in
      model) phrase='Select model'; expected=modal ;;
      rating) phrase='How is Claude doing this session?'; expected=survey-rating ;;
      survey) phrase='Can Anthropic look at your session transcript?'; expected=survey ;;
      trust) phrase='Yes, I trust this folder'; expected=trust ;;
      bypass) phrase='Bypass Permissions mode'; expected=modal ;;
      queue) phrase='Press up to edit queued messages'; expected=queued-dup ;;
    esac
    ok "diálogo activo $kind en $locale" "$(export LC_ALL="$locale"; _dialog "$kind" | tco_pane_anomaly)" "$expected"
    for indent in '' '  '; do
      ok "frase citada $kind sangría [$indent] en $locale" "$(export LC_ALL="$locale"; { printf '%s%s\n' "$indent" "$phrase"; cat "$REAL/idle.txt"; } | rc_of tco_pane_anomaly)" 1
      ok "bloque completo citado $kind sangría [$indent] en $locale" "$(export LC_ALL="$locale"; { _dialog "$kind" | sed "s/^/$indent/"; cat "$REAL/idle.txt"; } | rc_of tco_pane_anomaly)" 1
    done
    ok "diálogo posterior a cita $kind en $locale" "$(export LC_ALL="$locale"; { _dialog "$kind"; printf '\nRespuesta terminada\n'; _dialog "$kind"; } | tco_pane_anomaly)" "$expected"
    ok "frase sin ancla $kind en $locale" "$(export LC_ALL="$locale"; printf '%s' "$phrase" | tco_pane_anomaly)" "$expected"
  done
  for kind in survey trust bypass; do
    case "$kind" in survey) expected=survey ;; trust) expected=trust ;; *) expected=modal ;; esac
    ok "diálogo $kind debajo de compositor antiguo en $locale" "$(export LC_ALL="$locale"; { cat "$REAL/idle.txt"; _dialog "$kind"; } | tco_pane_anomaly)" "$expected"
  done
  ok "encuesta transcript íntegra pegada al compositor en $locale" "$(export LC_ALL="$locale"; { _dialog survey; sed -n '/^───/,$p' "$REAL/idle.txt"; } | tco_pane_anomaly)" survey
  ok "estado persistido con cita en $locale" "$(
    export LC_ALL="$locale"
    _tco_carril_session() { printf 'sid idle 1'; }
    _tco_transcript_lines() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"fin"}]}}'; }
    tco_cap_pane() { printf 'Select model\n'; cat "$REAL/idle.txt"; }
    rc_of tco_pane_busy 01 v:.0
  )" 1
  ok "wait idle con cita en $locale" "$(
    export LC_ALL="$locale"
    _tco_carril_session() { printf 'sid idle 1'; }
    _tco_transcript_lines() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"fin"}]}}'; }
    tco_cap_pane() { printf 'Select model\n'; cat "$REAL/idle.txt"; }
    sleep() { :; }
    TCO_AMBIG_MAX=1 rc_of tco_wait_idle 01 v:.0 120
  )" 0
done

_nudge() (
  local mode="$1" rc=0 n=0
  tco_pane_busy() { return 1; } # Autoridad en reposo; la captura todavía debe acreditar vacío.
  : > "$TMP_TEST/calls"; printf '0\n' > "$TMP_TEST/polls"
  incus() { printf '%s\n' "$*" >> "$TMP_TEST/calls"; }
  sleep() { :; }
  tco_cap_pane_e() {
    read -r n < "$TMP_TEST/polls"; n=$((n+1)); printf '%s\n' "$n" > "$TMP_TEST/polls"
    case "$mode" in
      foreign) sed 's/^❯.*/❯ texto de otra persona/' "$REAL/idle.txt" ;;
      wrapped) cat "$FX/wrapped-two.txt" ;;
      busy) cat "$REAL/busy.txt" ;;
      modal) cat "$REAL/modal.txt" ;;
      duplicate) sed 's/^❯.*/❯ continuemos continuemos/' "$REAL/idle.txt" ;;
      no-anchor) printf 'pantalla parcial\n' ;;
      *)
        if [ "$n" -eq 1 ] || { [ "$mode" = delayed ] && [ "$n" -le 3 ]; }; then cat "$REAL/idle.txt"
        elif [ "$mode" = changed ]; then cat "$FX/wrapped-two.txt"
        elif [ "$mode" = anomaly-after ]; then cat "$FX/survey-rating.txt"
        elif [ "$mode" = capture-failed ]; then sed 's/^❯.*/❯ continuemos/' "$REAL/idle.txt"; return 1
        else sed 's/^❯.*/❯ continuemos/' "$REAL/idle.txt"; fi ;;
    esac
  }
  TCO_RELAY_ECHO_POLLS=4 TCO_RELAY_ECHO_GAP=0 _tco_send_text_submit 01 v:.0 continuemos >/dev/null 2>&1 || rc=$?
  printf '%s:%s:%s' "$rc" "$(grep -c ' -l --' "$TMP_TEST/calls")" "$(grep -c ' C-m' "$TMP_TEST/calls")"
)
ok 'empujón vacío envía una vez con eco propio' "$(_nudge empty)" 0:1:1
ok 'eco tardío envía una vez sin reteclear' "$(_nudge delayed)" 0:1:1
for state in foreign wrapped busy modal duplicate no-anchor; do
  ok "empujón $state no teclea ni envía" "$(_nudge "$state")" 2:0:0
done
for state in changed anomaly-after capture-failed; do
  ok "eco $state no envía ni reteclea" "$(_nudge "$state")" 2:1:0
done
ok 'submit sin propiedad no envía' "$(
  incus() { printf 'TECLA'; }
  rc_of tco_send_submit 01 v:.0
)" 2
for kind in survey survey-rating; do
  ok "curación $kind obsoleta no teclea" "$(
    incus() { printf 'TECLA'; }
    tco_cap_pane() { cat "$REAL/idle.txt"; }
    rc_of tco_pane_heal 01 v:.0 "$kind"
  )" 2
done
for kind in model confirm trust; do
  ok "confirmación $kind sin diálogo acreditado no envía teclas" "$(
    incus() { printf 'TECLA'; }
    rc_of tco_send_dialog_choice 01 v:.0 "$kind" 1 yes
  )" 2
done
ok 'sesión ocupada prevalece sobre captura quieta' "$(
  _tco_carril_session() { printf 'sid busy 1'; }
  tco_pane_busy() { return 0; }
  tco_cap_pane_e() { cat "$REAL/idle.txt"; }
  rc_of tco_send_ready 01 v:.0
)" 2
ok 'estado desconocido prevalece sobre captura quieta' "$(
  tco_pane_busy() { return 2; }
  tco_cap_pane_e() { cat "$REAL/idle.txt"; }
  rc_of tco_send_ready 01 v:.0
)" 2
for sender in tco_send_dev tco_relay_file tco_queue_dev_file; do
  ok "envoltorio $sender preserva texto ajeno sin envío" "$(
    incus() { printf '%s\n' "$*" >> "$TMP_TEST/wrapper-calls"; }
    sleep() { :; }
    tco_wait_idle() { return 0; }
    tco_pane_busy() { return 1; }
    tco_cap_pane() { cat "$FX/wrapped-two.txt"; }
    tco_cap_pane_e() { cat "$FX/wrapped-two.txt"; }
    : > "$TMP_TEST/wrapper-calls"
    rc=0
    if [ "$sender" = tco_send_dev ]; then "$sender" 01 v:.0 continuemos >/dev/null 2>&1 || rc=$?
    else "$sender" 01 v:.0 "$REAL/idle.txt" brief >/dev/null 2>&1 || rc=$?; fi
    printf '%s:%s' "$rc" "$(grep -c send-keys "$TMP_TEST/wrapper-calls")"
  )" 2:0
done
for input in '/home/persona/repo' '/Users/persona/repo'; do
  ok 'capturador rechaza ruta personal original sin escribir' "$(
    rc=0
    printf '%s\n' "$input" | TCO_FIXTURE_DIR="$TMP_TEST/rejected" bash "$SC/capture-pane-fixtures.sh" --from-stdin --cli-version synthetic:1.0 idle >/dev/null 2>&1 || rc=$?
    printf '%s:%s' "$rc" "$([ -e "$TMP_TEST/rejected/synthetic_1.0/idle.txt" ] && echo escrito || echo ausente)"
  )" 3:ausente
done
# Lanzadores ejecutables: tmux respawn-pane ejecuta con bash -c y no lee el .bashrc, así que un alias no arranca el CLI.
# Bloques de lanzamiento REALES de dispatch.sh, audit-carril.sh y lib.sh sobre un doble de incus/tmux sin alias.
for mode in dispatch_sin_lanzadores dispatch_con_lanzadores dispatch_lanzadores_fuera_del_path dispatch_lanzador_no_ejecutable \
            dispatch_falta_el_del_auditor auditoria_sin_lanzador auditoria_con_lanzador relanzamiento_sin_lanzador \
            relanzamiento_con_lanzador orden_estatico identidad_lanzador_script identidad_lanzador_de_otro_agente \
            identidad_lanzador_sin_exec identidad_lanzador_destino_ausente preflight_con_lanzadores_script \
            dispatch_asignacion_path_sin_lanzadores dispatch_asignacion_path_con_lanzadores dispatch_asignacion_inverificable \
            auditoria_asignacion_path_ajena identidad_destino_ajeno_mismo_basename identidad_destino_ruta_canonica \
            preflight_dos_destinos_ajenos_comunes identidad_transporte_comilla_simple \
            dispatch_gramatica_asignacion dispatch_gramatica_env dispatch_gramatica_espacio dispatch_gramatica_punto_y_coma \
            dispatch_gramatica_dolar dispatch_gramatica_comillas dispatch_gramatica_ruta_relativa \
            dispatch_gramatica_auditor_asignacion auditoria_gramatica_asignacion relanzamiento_gramatica_asignacion \
            preparar_gramatica_asignacion \
            dispatch_r02_bash_env dispatch_r02_env_path dispatch_r02_env_i dispatch_r02_path_sin_agente \
            dispatch_lanzador_sin_agente dispatch_path_cliente_con_lanzadores dispatch_path_global_con_lanzadores_cliente_sin \
            identidad_r01_dos_sleep identidad_r05_path_del_pane identidad_r04_mismo_binario_real identidad_r04_nombres_declarados \
            dispatch_pane_muere_127 auditoria_pane_muere_127 relanzamiento_pane_muere_127 sonda_tmux_real \
            sonda_shell_del_servidor sonda_sesion_ausente sonda_colgada dispatch_shell_del_servidor \
            identidad_h02_enlaces_duros identidad_emite_inodo vida_remain_local vida_restauracion_falla \
            vida_estado_tardio vida_estado_nunca vida_senal \
            j5_orden_estatico j5_a_shell_cambiada j5_b_cwd_sin_lanzadores_en_repo j5_b_cwd_con_lanzadores_en_repo \
            j5_hook_after_new_window j5_identidad_acreditada j5_identidad_acreditada_execve j5_binario_symlink j5_binario_rename \
            j5_marcador_sin_marcador j5_marcador_nonce_distinto j5_marcador_ruta_relativa j5_marcador_ruta_inexistente \
            j5_marcador_permisos \
            j6_cuelgue_nunca j6_cuelgue_tarde j6_pane_died_hook j6_mensajes_rc j6_identidad_relanzamiento \
            j6_identidad_auditoria j6_acreditacion_forjada j6_destinos_estaticos \
            j7_n8_ventana_cambia j7_n9_acreditacion_rancia j7_pane_muere_tui j7_censo_destinos j7_eco_no_es_ack \
            j8_s1_soft j8_soft_dispatch j8_s3_vida j8_identidad_tras_ack j8_relanzamiento_ventanas \
            fase_tmux_real fase_misma_clave fase_negativos fase_dobles_pane_id \
            sistema_sin_agentes dispatch_shell_del_servidor_sistema_con_agentes sonda_shell_del_servidor_sistema_con_agentes \
            j5_a_shell_cambiada_sistema_con_agentes j5_b_cwd_sin_lanzadores_en_repo_sistema_con_agentes; do
  mode_log="$TMP_TEST/lanzador-$mode.log"
  mode_rc=0; env -u BASH_ENV -u ENV python3 "$TEST_DIR/launcher-dispatch-regressions.py" "$mode" > "$mode_log" 2>&1 || mode_rc=$?
  ok "lanzador ejecutable: $mode" "$mode_rc" 0
  [ "$mode_rc" -eq 0 ] || tail -n 12 "$mode_log"
  # Las anotaciones R11 (c) de un modo (sin directorio de testigos) salen al resumen, fuera del temporal que se borra al salir.
  grep -a '^ANOTADO R11c ' "$mode_log" || :
done
# Gramática CERRADA del CLI declarado (TCO_DEV_CLI/TCO_AUDIT_CLI): UN solo ejecutable —el nombre de un lanzador o una ruta
# absoluta—; los flags van en TCO_*_FLAGS. Cualquier otra forma se rechaza antes de lanzar nada.
for valid in claude-root codex-root claude codex /usr/bin/codex /opt/bin/claude-root /home/operador/.local/bin/claude-root; do
  ok "gramática del CLI: acepta $valid" "$(tco_cli_gramatica_motivo "$valid" >/dev/null 2>&1; echo $?)" 0
done
for invalid in '' 'PATH=/x claude-root' 'IS_SANDBOX=1 claude-root' 'A=b' 'env claude-root' 'env' 'claude-root --f' 'claude-root;rm x' \
               '$HOME/bin/claude-root' "'claude-root'" '"claude-root"' './claude-root' 'bin/claude-root' '-claude' '/opt/../bin/claude'; do
  ok "gramática del CLI: rechaza [$invalid]" "$(tco_cli_gramatica_motivo "$invalid" >/dev/null 2>&1; echo $?)" 1
done
ok 'gramática del CLI: el error del dev manda mover los flags a TCO_DEV_FLAGS' "$(tco_cli_gramatica TCO_DEV_CLI 'IS_SANDBOX=1 claude-root' 2>&1 | grep -c 'TCO_DEV_FLAGS')" 1
ok 'gramática del CLI: el error del auditor manda mover los flags a TCO_AUDIT_FLAGS' "$(tco_cli_gramatica TCO_AUDIT_CLI 'codex --x' 2>&1 | grep -c 'TCO_AUDIT_FLAGS')" 1
ok 'gramática del CLI: el error no imprime el valor de una credencial' "$(tco_cli_gramatica TCO_DEV_CLI 'ANTHROPIC_API_KEY=abc123456789 claude' 2>&1 | grep -c 'abc123456789')" 0
ok 'gramática del CLI: tco_require_agents la exige (rc 1 con asignación)' "$(
  (tco_modelos_config() { :; }; TCO_DEV_CLI='IS_SANDBOX=1 claude-root' TCO_AUDIT_CLI=codex tco_require_agents) >/dev/null 2>&1; echo $?)" 1
# R-04 y gramática en el preflight de identidad (seam _tco_pane_agent_exes con `real=<ruta real esperada>` tras el nombre).
pf_run() { # dev_cli audit_cli topologia exes_dev exes_aud [real_dev real_aud [ino_dev ino_aud]]
  PF_OUT="$(TCO_DEV_CLI="$1" TCO_AUDIT_CLI="$2" TCO_AUDIT_TOPOLOGY="$3" TCO_PANE_IDENT_WAIT=0 PF_DEV="$4" PF_AUD="$5" \
            PF_RDEV="${6-/fx/dev}" PF_RAUD="${7-/fx/aud}" PF_IDEV="${8-}" PF_IAUD="${9-}" bash -c '
    . "'"$SC"'/00-config.sh"; . "'"$SC"'/lib.sh"
    _tco_pane_agent_exes() {
      case "$2" in
        *.0) printf "%b" "$PF_DEV"; [ -z "$PF_RDEV" ] || printf "real=%s\n" "$PF_RDEV"; [ -z "$PF_IDEV" ] || printf "ino=%s\n" "$PF_IDEV" ;;
        *.1) printf "%b" "$PF_AUD"; [ -z "$PF_RAUD" ] || printf "real=%s\n" "$PF_RAUD"; [ -z "$PF_IAUD" ] || printf "ino=%s\n" "$PF_IAUD" ;;
      esac
    }
    tco_pane_identity_preflight 01' 2>&1)"; PF_RC=$?
}
pf_run claude-root codex-root distinto 'bash\nclaude\n' 'bash\ncodex\n'
ok 'preflight R-04: ejecutables reales distintos -> rc 0' "$PF_RC" 0
pf_run claude-root codex-root distinto 'bash\nclaude\n' 'bash\ncodex\n' /opt/agente /opt/agente
ok "preflight R-04: 'distinto' con el MISMO ejecutable real bajo nombres distintos -> rc 1" "$PF_RC" 1
ok 'preflight R-04: el error nombra el ejecutable real compartido' "$(printf '%s' "$PF_OUT" | grep -c 'MISMO ejecutable real (/opt/agente)')" 1
pf_run claude-root codex-root distinto 'bash\nclaude\n' 'bash\ncodex\n' '' ''
ok "preflight R-04: 'distinto' sin la ruta real de los panes -> rc 1 (no verificable = no pasa)" "$PF_RC" 1
pf_run claude-root claude-root mismo-adversarial 'bash\nclaude\n' 'bash\nclaude\n' /opt/agente /opt/agente
ok "preflight R-04: 'mismo-adversarial' ya no existe (ley del lead del 7-nov: el revisor es siempre Codex) -> rc 1" "$PF_RC" 1
pf_run 'IS_SANDBOX=1 claude-root' codex-root distinto 'bash\nclaude\n' 'bash\ncodex\n'
ok 'preflight: CLI del dev con asignación VAR=valor -> rc 1 (gramática cerrada)' "$PF_RC" 1
ok 'preflight: el error manda mover los flags a TCO_DEV_FLAGS' "$(printf '%s' "$PF_OUT" | grep -c 'TCO_DEV_FLAGS')" 1
# H-02: dos enlaces duros (rutas distintas, mismo dispositivo:inodo) son el MISMO ejecutable real.
pf_run claude-root codex-root distinto 'bash\nclaude\n' 'bash\ncodex\n' /opt/claude /opt/codex 65:100 65:100
ok "preflight H-02: 'distinto' con rutas distintas y el MISMO dispositivo:inodo (enlaces duros) -> rc 1" "$PF_RC" 1
ok 'preflight H-02: el error dice MISMO ejecutable real y el dispositivo:inodo' "$(printf '%s' "$PF_OUT" | grep -c 'MISMO ejecutable real.*65:100')" 1
pf_run claude-root codex-root distinto 'bash\nclaude\n' 'bash\ncodex\n' /opt/claude /opt/codex 65:100 65:101
ok "preflight H-02: rutas y dispositivo:inodo distintos -> rc 0" "$PF_RC" 0
pf_run claude-root codex-root distinto 'bash\nclaude\n' 'bash\ncodex\n' /opt/claude /opt/codex 65:100 ''
ok "preflight H-02: dispositivo:inodo de un solo pane -> rc 1 (no verificable = no pasa)" "$PF_RC" 1
# [issue 10264, H-1] audit-carril.sh LANZA el auditor: su guarda es la lista blanca de tco_ensure_audit_model (ejecutable exacto
# codex o codex-root), no un `case *claude*`. Se extrae del script REAL la sentencia de la guarda (2 líneas) y se ejecuta con la
# lib.sh real: ante un auditor que no es Codex muere con rc 1 ANTES de la línea «LANZADO», que simula el siguiente paso (el lanzamiento).
AC_GUARDA="$(sed -n '/^  tco_ensure_audit_model "\$CARRIL"/{N;p}' "$SC/audit-carril.sh")"
ok "audit-carril.sh: la guarda del auditor es tco_ensure_audit_model con tco_die y ya no queda el case *claude* (lista negra)" "$(printf '%s\n' "$AC_GUARDA" | grep -c .):$(printf '%s' "$AC_GUARDA" | grep -c 'tco_die'):$(grep -c 'in \*claude\*) tco_die' "$SC/audit-carril.sh")" '2:1:0'
ac_guarda_run() { # TCO_AUDIT_CLI → «rc:líneas LANZADO:mensajes de parada del script»
  local rc=0 out
  out="$(TCO_AUDIT_CLI="$1" AC_G="$AC_GUARDA" bash -c '
    . "'"$SC"'/00-config.sh"; . "'"$SC"'/lib.sh"
    CARRIL=01
    eval "$AC_G"
    echo LANZADO' 2>&1)" || rc=$?
  printf '%s:%s:%s' "$rc" "$(printf '%s\n' "$out" | grep -c '^LANZADO$')" "$(printf '%s\n' "$out" | grep -c 'no se lanza el auditor; se PARA y se escala')"
}
for aud in codexx codex-evil codex-root.sh codexfalso-root gemini; do
  ok "audit-carril.sh: auditor '$aud' ⇒ PARA (rc 1) con «se PARA y se escala» ANTES de lanzar nada" "$(ac_guarda_run "$aud")" '1:0:1'
done
for aud in codex codex-root /x/codex-root; do
  ok "audit-carril.sh: auditor '$aud' ⇒ la guarda deja pasar (rc 0) y llega al lanzamiento" "$(ac_guarda_run "$aud")" '0:1:0'
done
printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] && [ "$((PASS+FAIL))" -eq 268 ]
