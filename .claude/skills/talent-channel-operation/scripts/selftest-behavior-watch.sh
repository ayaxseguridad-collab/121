#!/usr/bin/env bash
# selftest-behavior-watch.sh — Selftest de behavior-watch.sh y run-state-write.sh. Sin flota:
# todo en temporales (SECRET_DIR, runs, bus con perfil de prueba, JSONL, git, /proc) y con el bus-sellar.sh y
# el bus-leer.sh REALES del paquete, así que el contrato rc 0/2/3 del sellador se ejercita de verdad.
#
# Regla de los negativos: UNA sola condición falsa y todas las demás verdaderas, y cada negativo lleva su
# CONTROL (la misma fixture con esa condición verdadera -> el token vota). Salida: una línea PASS/FAIL por
# aserción con el nombre del caso; contadores PASS, FAIL y SKIP; TOTAL == TOTAL_ESPERADO o rc 1.
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2317,SC2329
# SC1091: behavior-watch.sh y los stubs se generan/resuelven en tiempo de ejecución · SC2016: los `bash -c`
# llevan su script entre comillas simples a propósito · SC2030/SC2031: cada caso exporta su entorno en un
# subshell `( … )` precisamente para que NO se filtre al siguiente · SC2317/SC2329: las funciones p_* (prepara) se
# invocan indirectamente desde par().
set -uo pipefail
SC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEO="$SC/../../talent-ceo/scripts"
TOTAL_ESPERADO=227   # derivado del código: 96 chk − 3 de par − 4 de wfs + 25 par×3 + 7 wfs×4 + 2 + 3 de los bucles + 4 del caso C11 + 26 de las correcciones (8 escritor atómico + 6 TEXTO/HERRAMIENTA + 8 CPU-STAT + 4 REPORT-NUEVO)
PASS=0; FAIL=0; SKIP=0
chk() { # caso descripción obtenido esperado
  if [ "$3" = "$4" ]; then PASS=$((PASS+1)); printf 'PASS %s: %s\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf 'FAIL %s: %s (esperado [%s] obtenido [%s])\n' "$1" "$2" "$4" "$3"; fi
}

T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf -- "${T:?}"' EXIT
export XDG_RUNTIME_DIR="$T/xdg"; mkdir -m 700 "$XDG_RUNTIME_DIR"
# Identidad de la instancia, con el mismo criterio que tests/run-tests.sh: SIN scripts/repo-identity.conf (distribución) se
# exporta una identidad NEUTRA por env, sin pisar la que ya exportó quien nos llama; CON conf (instancia) no se exporta nada
# (un env distinto del conf sería un OVERRIDE DIVERGENTE de 00-config.sh). HOST_HOME apunta a un directorio temporal.
export HOST_HOME="${HOST_HOME:-$T/home}"; mkdir -p "$HOST_HOME"
if [ ! -f "$SC/repo-identity.conf" ]; then
  export TCO_REPO_DIR="${TCO_REPO_DIR:-Repo-Neutro}" TCO_REPO_SLUG="${TCO_REPO_SLUG:-org-neutra/Repo-Neutro}" \
    TCO_REPO_STACK="${TCO_REPO_STACK:-ninguno}" TCO_ANEXO_FILE="${TCO_ANEXO_FILE:-references/anexo-neutro.md}" \
    TCO_LINEAR_INPROGRESS_STATE="${TCO_LINEAR_INPROGRESS_STATE:-estado-en-curso}" \
    TCO_LINEAR_INREVIEW_STATE="${TCO_LINEAR_INREVIEW_STATE:-estado-en-revision}" \
    TCO_HOST_ENV_REL="${TCO_HOST_ENV_REL:-Repo-Neutro/.env.local}"
fi
CANAL=46
CENTINELA="CENTINELA-$$-no-debe-salir"

# ── Perfil de prueba: una máquina local y un rol con el usuario REAL del proceso (bus-sellar lo verifica) ──
PERFIL="$T/perfil.tsv"
{ printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-prueba\tmaq-prueba\t-\t-\tacceso=local\n'
  printf 'torre\tcoord-prueba\tmaq-prueba\t-\t-\tusuario=%s\n' "$(id -un)"; } > "$PERFIL"

# ── Stubs: gh, ejecutor de /proc (corre el script REAL del helper sobre un /proc y un pgrep falsos) ──
mkdir -p "$T/bin" "$T/fakebin"
cat > "$T/bin/gh-stub" <<'EOF'
#!/usr/bin/env bash
[ -f "$BW_CASO/gh_sleep" ] && sleep "$(cat "$BW_CASO/gh_sleep")"
[ -f "$BW_CASO/gh_rc" ] && exit "$(cat "$BW_CASO/gh_rc")"
printf '{"state":"%s","mergedAt":null}\n' "$(cat "$BW_CASO/gh_state" 2>/dev/null || echo OPEN)"
EOF
cat > "$T/bin/proc-stub" <<'EOF'
#!/usr/bin/env bash
s="${2//\/proc\//$BW_CASO/proc/}"
# proc_corta: la lectura llega CORTADA (sin la marca final TCO-FIN)
if [ -f "$BW_CASO/proc_corta" ]; then PATH="$BW_FAKEBIN:$PATH" bash -c "$s" | grep -v '^TCO-FIN$'; exit 0; fi
PATH="$BW_FAKEBIN:$PATH" bash -c "$s"
EOF
# sub-stub: ejecuta en local el script REAL de _bw_subagent_bytes, con la ruta <…>/<sid>/subagents del contenedor
# apuntando a la de la fixture ($BW_CASO/<sid>/subagents). Así la lectura (y su fallo) es la del código, no un stub.
cat > "$T/bin/sub-stub" <<'EOF'
#!/usr/bin/env bash
# el script define b='<proyecto>' y deriva <sid> y subagents: el proyecto de la fixture es $BW_CASO.
s="$(printf '%s' "$2" | sed "s#^b='/home/[^']*'#b='$BW_CASO'#")"
bash -c "$s"
EOF
cat > "$T/fakebin/pgrep" <<'EOF'
#!/usr/bin/env bash
# pgrep_roto: pgrep falla (rc 3), que NO es «sin hijos» (rc 1)
[ -f "$BW_CASO/pgrep_roto" ] && exit 3
# pgrep_roto_para: falla (rc 3) SOLO para los hijos de ese pid (un nivel profundo)
[ -f "$BW_CASO/pgrep_roto_para" ] && [ "${2:-}" = "$(cat "$BW_CASO/pgrep_roto_para")" ] && exit 3
[ "${1:-}" = -P ] || exit 2
out="$(awk -v p="$2" '$1 == p { print $2 }' "$BW_CASO/arbol" 2>/dev/null)"
[ -n "$out" ] || exit 1
printf '%s\n' "$out"
EOF
cat > "$T/bin/escribe-mitad" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$1" | head -c 10
EOF
# escribe-bloqueado: se queda a medias de la escritura (aviso en dentro-W) hasta que el caso crea suelta-W.
cat > "$T/bin/escribe-bloqueado" <<'EOF'
#!/usr/bin/env bash
: > "$BW_CASO/dentro-W"
while [ ! -e "$BW_CASO/suelta-W" ]; do sleep 0.05; done
printf '%s\n' "$1"
EOF
chmod +x "$T/bin/"* "$T/fakebin/"*

# Seams del detector: sesión, transcript, git y pid de claude leídos de la fixture del caso.
cat > "$T/stubs.sh" <<'EOF'
_tco_carril_session() {
  [ -f "$BW_CASO/session" ] || return 1
  if [ -n "${BW_BLOQUEA:-}" ]; then : > "$BW_CASO/dentro-A"; while [ ! -e "$BW_CASO/suelta-A" ]; do sleep 0.1; done; fi
  cat "$BW_CASO/session"
}
_tco_carril_transcript() { [ -f "$BW_CASO/t.jsonl" ] || return 1; wc -c < "$BW_CASO/t.jsonl" | tr -d ' '; cat "$BW_CASO/t.jsonl"; }
_tco_carril_git() {
  [ -f "$BW_CASO/head" ] || return 1
  case "$2" in rev-parse) cat "$BW_CASO/head" ;; status) cat "$BW_CASO/porcelain" 2>/dev/null; return 0 ;; esac
}
_bw_claude_pid() { [ -f "$BW_CASO/claude_pid" ] || return 1; cat "$BW_CASO/claude_pid"; }
EOF

pst() { # caso pid comm utime stime
  mkdir -p "$1/proc/$2"
  printf '%s (%s) S 1 1 1 0 -1 4194304 0 0 0 0 %s %s 0 0 20 0 1 0 1000 1000 100 1 1 1 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n' \
    "$2" "$3" "$4" "$5" > "$1/proc/$2/stat"
}
# Fixture base: sesión busy, transcript con un tool_use cerrado que lleva la CENTINELA en input y resultado,
# git, claude (pid 100, comm con «) » dentro) con un hijo (200), y un run vigente del canal sin PR.
fx() { # caso
  local C="$T/c/$1"; mkdir -p "$C/runs/ABC-1" "$C/locks"; : > "$C/bus"
  printf 'sid-1 busy 2026-09-24T00:00:00Z 2.1.0\n' > "$C/session"
  { printf '{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo %s"}}]}}\n' "$CENTINELA"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"%s"}]}}\n' "$CENTINELA"; } > "$C/t.jsonl"
  printf '1111111111111111111111111111111111111111\n' > "$C/head"; : > "$C/porcelain"
  printf '100 200\n' > "$C/arbol"; printf '100\n' > "$C/claude_pid"
  pst "$C" 100 'claude) x' 500 500; pst "$C" 200 'node' 5 5
  printf '{"run_id":"ABC-1","carril":"%s","phase":"active"}\n' "$CANAL" > "$C/runs/ABC-1/state.json"
  printf '%s' "$C"
}
env_caso() { # caso
  export BW_CASO="$1" SECRET_DIR="$1" TCO_RUNS_DIR="$1/runs" TCO_BEHAVIOR_DIR="$1/behavior" TCO_LOCK_DIR="$1/locks" \
    TA_BUS="$1/bus" TA_BUS_LOCK="$1/bus.lock" TA_BUS_CURSOR_DIR="$1/cur" TC_STALL_WINDOW=60 \
    TC_GH_TIMEOUT="${GH_TO:-5}" TCO_GH_CMD="$T/bin/gh-stub" TCO_PROC_CMD="$T/bin/proc-stub" TCO_SUBAG_CMD="$T/bin/sub-stub" BW_FAKEBIN="$T/fakebin" \
    TA_PERFIL="$PERFIL" TA_ROL="${ROL-coord-prueba}"
}
tick() { # caso [--report-only] -> OUT RC
  local C="$1"; shift
  OUT="$( env_caso "$C"; . "$SC/behavior-watch.sh"; . "$T/stubs.sh"; bw_main "$CANAL" "$@" 2>>"$C/err" )"; RC=$?
  printf '%s\n' "$RC" >> "$T/rcs"; printf '%s\n' "$OUT" >> "$T/salidas"   # insumo del caso C11
}
envejecer() { # caso segundos [solo-transcript-segundos]
  local st="$1/behavior/$CANAL.state" tmp
  tmp="$(mktemp)"; jq --argjson s "$2" --argjson t "${3:-$2}" \
    '.obs_ts -= $s | (if .transcript then .transcript.since -= $t else . end) | (if .git then .git.since -= $s else . end)' "$st" > "$tmp" && mv "$tmp" "$st"
}
sellos() { grep -c '\[marcador: VIGIA-' "$1/bus"; }
estado_tok() { jq -r '.tokens["PROGRESO-ESTANCADO"].estado // "ninguno"' "$1/behavior/$CANAL.state"; }
rsw() { # caso args... (run-state-write con la raíz de runs del caso)
  ( env_caso "$1"; shift; bash "$SC/run-state-write.sh" "$@" ) 2>>"$T/rsw.err"
}
# Par negativo + control: la MISMA fixture; el control deja la condición verdadera (vota rc 22), el negativo la
# hace falsa con <prepara> ANTES del segundo tick (el primero abre las ventanas y se envejece 100 s).
par() { # caso rc-esperado prepara-fn
  local C; C="$(fx "$1-control")"; tick "$C"; envejecer "$C" 100; tick "$C"
  chk "$1" "control (la condición verdadera) vota rc 22" "$RC" 22
  C="$(fx "$1")"; tick "$C"; envejecer "$C" 100; "$3" "$C"; tick "$C"
  chk "$1" "con SOLO esa condición falsa -> rc $2" "$RC" "$2"
  chk "$1" "0 sellos en el bus" "$(sellos "$C")" 0
}

echo "== PROGRESO-ESTANCADO: primer tick, positivo, sello y segundo tick =="
C="$(fx POS)"; tick "$C"
chk PRIMER-TICK "el primer tick abre ventanas y NO vota (rc 0)" "$RC" 0
chk PRIMER-TICK "0 sellos tras el primer tick" "$(sellos "$C")" 0
envejecer "$C" 100; tick "$C"
chk POS-STALL "transcript, git y CPU de los hijos quietos -> rc 22" "$RC" 22
chk POS-STALL "la línea nombra PROGRESO-ESTANCADO" "$(printf '%s' "$OUT" | grep -c '^behavior: PROGRESO-ESTANCADO · rc 22 · liveness=busy · active_run=ABC-1 run_reason=ok')" 1
chk POS-STALL "la línea no trae phase_age, loop= ni recency=" "$(printf '%s' "$OUT" | grep -cE 'phase_age|loop=|recency=')" 0
chk POS-STALL "un sello VIGIA-PROGRESO-ESTANCADO-$CANAL-<epoch> con el sellador REAL" "$(grep -cE "\[marcador: VIGIA-PROGRESO-ESTANCADO-$CANAL-[0-9]+\]" "$C/bus")" 1
chk POS-STALL "rc 0 del sellador -> avisado" "$(estado_tok "$C")" avisado
chk P2-I "encargo activo sin ningún lock vota (locks vacío)" "$(find "$C/locks" -type f | wc -l)" 0
tick "$C"
chk SELLO-SEGUNDO "segundo tick con el token aún verdadero: rc 22" "$RC" 22
chk SELLO-SEGUNDO "0 sellos nuevos" "$(sellos "$C")" 1
chk S-NO-TEXTO "control: la centinela SÍ está en el transcript" "$(grep -c "$CENTINELA" "$C/t.jsonl")" 2
chk S-NO-TEXTO "0 apariciones en la salida" "$(printf '%s' "$OUT" | grep -c "$CENTINELA")" 0
chk S-NO-TEXTO "0 apariciones en el estado" "$(grep -c "$CENTINELA" "$C/behavior/$CANAL.state")" 0
chk S-NO-TEXTO "0 apariciones en el bus" "$(grep -c "$CENTINELA" "$C/bus")" 0
C_POS="$C"

echo "== P1: sesión =="
p_idle() { printf 'sid-1 idle 2026-09-24T00:00:00Z 2.1.0\n' > "$1/session"; }
par N-P1-IDLE 1 p_idle
p_unk() { printf 'sid-1 raro 2026-09-24T00:00:00Z 2.1.0\n' > "$1/session"; }
par N-P1-UNK 2 p_unk
chk N-P1-UNK "UNKNOWN: la línea dice UNKNOWN" "$(printf '%s' "$OUT" | grep -c '^behavior: UNKNOWN · rc 2 · liveness=unknown')" 1

# La corroboración de turno en vuelo es ESTRUCTURAL: el texto de un mensaje de usuario no cambia el veredicto. Sesión idle con
# el último registro un mensaje de usuario (string): con texto neutro y con prefijo de comando local da lo mismo (idle, rc 1).
idle_texto() { # caso registro-json -> OUT RC
  local C; C="$(fx "$1")"; printf 'sid-1 idle 2026-09-24T00:00:00Z 2.1.0\n' > "$C/session"; printf '%s\n' "$2" >> "$C/t.jsonl"
  tick "$C"; envejecer "$C" 100; tick "$C"
}
idle_texto TEXTO-IDLE-NEUTRO '{"type":"user","message":{"content":"orden neutra"}}'
chk TEXTO-IDLE-NEUTRO "idle con un mensaje de usuario sin respuesta (texto neutro): rc 1" "$RC" 1
chk TEXTO-IDLE-NEUTRO "liveness=idle" "$(printf '%s' "$OUT" | grep -c 'liveness=idle')" 1
idle_texto TEXTO-IDLE-CMD '{"type":"user","message":{"content":"<command-name>x</command-name>"}}'
chk TEXTO-IDLE-CMD "idle con prefijo de comando local: el mismo rc 1 (el texto no decide)" "$RC" 1
chk TEXTO-IDLE-CMD "liveness=idle" "$(printf '%s' "$OUT" | grep -c 'liveness=idle')" 1
idle_texto IDLE-HERRAMIENTA-PENDIENTE '{"type":"assistant","uuid":"a9","message":{"content":[{"type":"tool_use","id":"tu9","name":"Bash","input":{"command":"x"}}]}}'
chk IDLE-HERRAMIENTA-PENDIENTE "idle con un tool_use sin tool_result: la señal estructural degrada a busy -> rc 22" "$RC" 22
chk IDLE-HERRAMIENTA-PENDIENTE "liveness=busy" "$(printf '%s' "$OUT" | grep -c 'liveness=busy')" 1

echo "== P2: run vigente =="
p_norun() { rm -f -- "${1:?}/runs/ABC-1/state.json"; }
par N-P2-NO 0 p_norun
chk N-P2-NO "active_run=no run_reason=no_state" "$(printf '%s' "$OUT" | grep -c 'active_run=no run_reason=no_state')" 1
p_term() { printf '{"carril":"%s","phase":"done"}\n' "$CANAL" > "$1/runs/ABC-1/state.json"; }
par N-P2-TERM 0 p_term
chk N-P2-TERM "run_reason=terminal" "$(printf '%s' "$OUT" | grep -c 'run_reason=terminal')" 1
p_pr() { printf '{"carril":"%s","phase":"active","pr":12}\n' "$CANAL" > "$1/runs/ABC-1/state.json"; printf 'MERGED' > "$1/gh_state"; }
par N-P2-PR 0 p_pr
chk N-P2-PR "run_reason=pr_merged" "$(printf '%s' "$OUT" | grep -c 'run_reason=pr_merged')" 1
C="$(fx P2-II)"; printf '{"carril":"%s","phase":"active","pr":12}\n' "$CANAL" > "$C/runs/ABC-1/state.json"
mkdir -p "$C/approvals"; : > "$C/approvals/12-abc.ok"; : > "$C/locks/merge-12.lock"
tick "$C"; envejecer "$C" 100; tick "$C"
chk P2-II "approvals/<pr>.ok + lock presentes y gh=OPEN -> vota rc 22" "$RC" 22
for st in MERGED CLOSED; do
  C="$(fx "P2-III-$st")"; printf '{"carril":"%s","phase":"active","pr":12}\n' "$CANAL" > "$C/runs/ABC-1/state.json"; printf '%s' "$st" > "$C/gh_state"
  tick "$C"; envejecer "$C" 100; cp -a "$C/behavior" "$C/behavior.antes"; tick "$C"; sin="$OUT"; rsin=$RC
  rm -rf -- "${C:?}/behavior"; mv "$C/behavior.antes" "$C/behavior"
  mkdir -p "$C/approvals"; : > "$C/approvals/12-abc.ok"; : > "$C/locks/merge-12.lock"; tick "$C"
  chk P2-III "gh=$st no vota (rc 0)" "$rsin" 0
  chk P2-III "gh=$st: resultado idéntico con y sin .ok/lock" "$(printf '%s' "$OUT" | sed 's/bus_last=[^ ]*//')" "$(printf '%s' "$sin" | sed 's/bus_last=[^ ]*//')"
done
chk P2-CLOSED "gh=CLOSED -> run_reason=pr_closed" "$(printf '%s' "$OUT" | grep -c 'run_reason=pr_closed')" 1
for modo in rc timeout; do
  C="$(fx "P2-IV-$modo")"; printf '{"carril":"%s","phase":"active","pr":12}\n' "$CANAL" > "$C/runs/ABC-1/state.json"
  tick "$C"; envejecer "$C" 100
  if [ "$modo" = rc ]; then printf '1' > "$C/gh_rc"; else printf '3' > "$C/gh_sleep"; fi
  antes="$(wc -l < "$C/bus")"; GH_TO=1 tick "$C"
  chk P2-IV "gh $modo -> UNKNOWN rc 2" "$RC" 2
  chk P2-IV "gh $modo -> run_reason=pr_unknown" "$(printf '%s' "$OUT" | grep -c 'run_reason=pr_unknown')" 1
  chk P2-IV "gh $modo -> wc -l del bus sin cambio" "$(wc -l < "$C/bus")" "$antes"
done
p_sincarril() { mkdir -p "$1/runs/ABC-7"; printf '{"run_id":"ABC-7","phase":"code","pr":3}\n' > "$1/runs/ABC-7/state.json"; }
par STATE-SIN-CARRIL 2 p_sincarril
chk STATE-SIN-CARRIL "run_reason=state_unreadable" "$(printf '%s' "$OUT" | grep -c 'run_reason=state_unreadable')" 1

echo "== PROGRESO-ESTANCADO: una condición falsa cada vez =="
p_t() { printf '{"type":"system","subtype":"x"}\n' >> "$1/t.jsonl"; }
par N-STALL-1 0 p_t
p_git() { printf '2222222222222222222222222222222222222222\n' > "$1/head"; }
par N-STALL-2 0 p_git
p_por() { printf ' M fichero.txt\n' > "$1/porcelain"; }
par N-STALL-2-PORCELAIN 0 p_por
p_cpu() { pst "$1" 200 'node' 6 5; }
par N-STALL-3 0 p_cpu
chk N-STALL-3 "cpu_delta=1" "$(printf '%s' "$OUT" | grep -c 'cpu_delta=1 ')" 1
C="$(fx THINKING-LARGO)"; tick "$C"; envejecer "$C" 100 30; tick "$C"
chk THINKING-LARGO "transcript quieto MENOS que la ventana (git y CPU quietos): no vota" "$RC" 0
p_gate() { printf '100 200\n200 300\n' > "$1/arbol"; pst "$1" 300 'vitest' 90 10; }
C="$(fx GATE-VIVO)"; printf '100 200\n200 300\n' > "$C/arbol"; pst "$C" 300 'vitest' 80 10; tick "$C"; envejecer "$C" 100; p_gate "$C"; tick "$C"
chk GATE-VIVO "un gate nieto con CPU que avanza: no vota" "$RC" 0
chk GATE-VIVO "los nietos cuentan (cpu_delta=10)" "$(printf '%s' "$OUT" | grep -c 'cpu_delta=10 ')" 1
C="$(fx POLLING-LOG)"; tick "$C"; envejecer "$C" 100; printf '{"type":"progress"}\n' >> "$C/t.jsonl"; tick "$C"
chk POLLING-LOG "polling con log que avanza (transcript crece): no vota" "$RC" 0
p_claude() { pst "$1" 100 'claude) x' 900 900; }
C="$(fx D2-CLAUDE-CPU)"; tick "$C"; envejecer "$C" 100; p_claude "$C"; tick "$C"
chk D2-CLAUDE-CPU "la CPU del propio claude avanza y la de los hijos no: STALL vota (el propio claude no cuenta)" "$RC" 22
C="$(fx SIN-HIJOS)"; : > "$C/arbol"; tick "$C"; envejecer "$C" 100; tick "$C"
chk SIN-HIJOS "sin hijos: la condición (3) es verdadera y vota" "$RC" 22
chk SIN-HIJOS "cpu_delta=none" "$(printf '%s' "$OUT" | grep -c 'cpu_delta=none')" 1
p_proc_roto() { rm -f -- "${1:?}/claude_pid"; }
par CPU-ILEGIBLE 2 p_proc_roto
p_t_y_proc() { printf '{"type":"x"}\n' >> "$1/t.jsonl"; rm -f -- "${1:?}/claude_pid"; }
par FUENTE-NO-ESENCIAL 0 p_t_y_proc
# la regla de ausencia, con caso para las dos fuentes que no lo tenían: git ilegible y /proc cortado
p_git_roto() { rm -f -- "${1:?}/head"; }
par GIT-ILEGIBLE 2 p_git_roto
p_proc_corta() { : > "$1/proc_corta"; }
par CPU-CORTADA 2 p_proc_corta
# la VENTANA de git: git cambió DENTRO de la ventana y ANTES del último tick (como THINKING-LARGO
# para el transcript). Control: la misma secuencia sin el commit -> vota.
C="$(fx N-STALL-2-VENTANA-control)"; tick "$C"; envejecer "$C" 100; tick "$C"; envejecer "$C" 30; tick "$C"
chk N-STALL-2-VENTANA "control (git quieto toda la ventana) vota rc 22" "$RC" 22
C="$(fx N-STALL-2-VENTANA)"; tick "$C"; envejecer "$C" 100; p_git "$C"; tick "$C"; envejecer "$C" 30; tick "$C"
chk N-STALL-2-VENTANA "git cambió hace 30 s (< ventana), no en el último tick: no vota (rc 0)" "$RC" 0
chk N-STALL-2-VENTANA "0 sellos en el bus" "$(sellos "$C")" 0
# un subagente trabajando: escribe en <sid>/subagents/*.jsonl y el principal está quieto -> no vota
p_sub() { mkdir -p "$1/sid-1/subagents"; printf '{"type":"assistant"}\n' >> "$1/sid-1/subagents/agent-x.jsonl"; }
par N-SUBAGENTE 0 p_sub
# subagentes ILEGIBLES DE VERDAD: el directorio existe y este usuario no lo puede leer ni
# recorrer (chmod 000). La lectura real falla -> (1) no medible -> UNKNOWN rc 2 y 0 sellos; nunca «0 bytes, quieto».
C="$(fx SUB-ILEGIBLE-pre)"; mkdir -p "$C/sid-1/subagents"; chmod 000 "$C/sid-1/subagents"
chk SUB-ILEGIBLE "precondición: este usuario NO puede leer el directorio (si sale legible, p. ej. como root, el caso no mide)" "$([ -r "$C/sid-1/subagents" ] && echo legible || echo ilegible)" ilegible
p_sub_ilegible() { mkdir -p "${1:?}/sid-1/subagents"; chmod 000 "$1/sid-1/subagents"; }
par SUB-ILEGIBLE 2 p_sub_ilegible
# Espejo en la condición (3): pgrep falla (rc 3): no es «sin hijos» -> sin TCO-FIN -> UNKNOWN rc 2, 0 sellos
p_pgrep_roto() { : > "${1:?}/pgrep_roto"; }
par CPU-PGREP-ROTO 2 p_pgrep_roto
# la ausencia de subagents solo vale como 0 si se PRUEBA: con <sid> sin permiso de recorrido (000, o 600
# sin x) `test -e subagents` da falso por EACCES. Con un subagente dentro, eso NO es «0 bytes»: UNKNOWN, 0 sellos.
C="$(fx SUB-PADRE-pre)"; mkdir -p "$C/sid-1/subagents"; chmod 000 "$C/sid-1"
chk SUB-PADRE-000 "precondición: este usuario NO puede recorrer <sid> (si sale recorrible, p. ej. como root, el caso no mide)" "$([ -x "$C/sid-1" ] && echo recorrible || echo no-recorrible)" no-recorrible
p_sid_000() { mkdir -p "${1:?}/sid-1/subagents"; printf '{"type":"assistant"}\n' > "$1/sid-1/subagents/agent-x.jsonl"; chmod 000 "$1/sid-1"; }
par SUB-PADRE-000 2 p_sid_000
p_sid_600() { mkdir -p "${1:?}/sid-1/subagents"; printf '{"type":"assistant"}\n' > "$1/sid-1/subagents/agent-x.jsonl"; chmod 600 "$1/sid-1"; }
par SUB-PADRE-600 2 p_sid_600
# el fallo de pgrep desde un nivel PROFUNDO se propaga: falla solo para los hijos de 200 y hay un
# hermano 250 DESPUÉS (si el que falla fuese el último, quitar la propagación sería equivalente).
p_pgrep_nieto() { printf '100 250\n' >> "${1:?}/arbol"; pst "$1" 250 'node' 0 0; printf '200\n' > "$1/pgrep_roto_para"; }
par CPU-PGREP-NIETO 2 p_pgrep_nieto
# claude terminó entre la resolución del pid y la lectura de CPU: sin /proc/<pid> no es «sin hijos».
p_pid_muerto() { rm -rf -- "${1:?}/proc/100"; : > "$1/arbol"; }
par CPU-PID-MUERTO 2 p_pid_muerto
# Un hijo VIVO (su /proc/<pid> existe) cuyo stat no se lee es «desconocido», no «sin hijos»: se reintenta y, si persiste,
# la condición (3) no es medible -> UNKNOWN rc 2, 0 sellos. Solo un hijo que ya no existe deja de contar.
p_stat_ausente() { rm -f -- "${1:?}/proc/200/stat"; }
par CPU-STAT-AUSENTE 2 p_stat_ausente
C="$(fx CPU-STAT-ILEGIBLE-pre)"; chmod 000 "$C/proc/200/stat"
chk CPU-STAT-ILEGIBLE "precondición: este usuario NO puede leer el stat (si sale legible, p. ej. como root, el caso no mide)" "$([ -r "$C/proc/200/stat" ] && echo legible || echo ilegible)" ilegible
p_stat_ilegible() { chmod 000 "${1:?}/proc/200/stat"; }
par CPU-STAT-ILEGIBLE 2 p_stat_ilegible
C="$(fx CPU-HIJO-TERMINADO)"; rm -rf -- "${C:?}/proc/200"; tick "$C"; envejecer "$C" 100; tick "$C"
chk CPU-HIJO-TERMINADO "un hijo listado por pgrep que ya no existe no suma ni bloquea: la condición (3) es verdadera -> rc 22" "$RC" 22
# subagents es un ENLACE a un directorio y un subagente escribe: se sigue el enlace, no vota.
p_sub_enlace() { mkdir -p "${1:?}/sid-1" "$1/sub-real"; ln -s "$1/sub-real" "$1/sid-1/subagents"; printf '{"type":"assistant"}\n' >> "$1/sub-real/agent-x.jsonl"; }
par N-SUBAGENTE-ENLACE 0 p_sub_enlace
# ENLACES que no se resuelven: subagents (o <sid>) enlazado a un destino bajo un directorio sin permiso
# de recorrido. `test -e` da falso por EACCES, y eso no es «no existe». Con un subagente escribiendo -> UNKNOWN, 0 sellos.
C="$(fx SUB-ENLACE-CERRADO-pre)"; mkdir -p "$C/cerrado/sub-real"; chmod 000 "$C/cerrado"
chk SUB-ENLACE-CERRADO "precondición: este usuario NO puede recorrer el directorio del destino (si sale recorrible, p. ej. como root, el caso no mide)" "$([ -x "$C/cerrado" ] && echo recorrible || echo no-recorrible)" no-recorrible
p_sub_enlace_cerrado() { mkdir -p "${1:?}/sid-1" "$1/cerrado/sub-real"; printf '{"type":"assistant"}\n' >> "$1/cerrado/sub-real/agent-x.jsonl"; ln -s "$1/cerrado/sub-real" "$1/sid-1/subagents"; chmod 000 "$1/cerrado"; }
par SUB-ENLACE-CERRADO 2 p_sub_enlace_cerrado
p_sid_enlace_cerrado() { mkdir -p "${1:?}/cerrado/sid-real/subagents"; printf '{"type":"assistant"}\n' >> "$1/cerrado/sid-real/subagents/agent-x.jsonl"; ln -s "$1/cerrado/sid-real" "$1/sid-1"; chmod 000 "$1/cerrado"; }
par SID-ENLACE-CERRADO 2 p_sid_enlace_cerrado
# una entrada *.jsonl de subagents que NO es un fichero regular (un enlace a
# un fichero que crece) no se salta en silencio: la suma no la puede medir -> UNKNOWN, 0 sellos.
p_jsonl_enlace() { mkdir -p "${1:?}/sid-1/subagents" "$1/fuera"; printf '{"type":"assistant"}\n' >> "$1/fuera/agent-x.jsonl"; ln -s "$1/fuera/agent-x.jsonl" "$1/sid-1/subagents/agent-x.jsonl"; }
par SUB-JSONL-ENLACE 2 p_jsonl_enlace
# la rama del DIRECTORIO DEL PROYECTO, a nivel de la función REAL (por la costura sub-stub): en
# el detector la tapa la lectura del transcript principal (vive en el mismo directorio), así que se mide aquí. Sin
# <sid> y con el proyecto sin recorrido (000, o 600 sin x): no se puede saber -> rc 1, nunca «0».
fsub() { # proyecto -> OUT RC
  OUT="$( env_caso "$1"; . "$SC/behavior-watch.sh"; . "$T/stubs.sh"; _bw_subagent_bytes "$CANAL" sid-1 2>/dev/null )"; RC=$?
}
P="$T/c/F-PROY-CONTROL"; mkdir -p "$P"; fsub "$P"
chk F-PROY-CONTROL "sin <sid> y el proyecto recorrible: la ausencia se prueba -> «0», rc 0 (el contrario)" "$RC $OUT" "0 0"
P="$T/c/F-PROY-000"; mkdir -p "$P"; chmod 000 "$P"
chk F-PROY-000 "precondición: este usuario NO puede recorrer el proyecto (si sale recorrible, p. ej. como root, el caso no mide)" "$([ -x "$P" ] && echo recorrible || echo no-recorrible)" no-recorrible
fsub "$P"; chk F-PROY-000 "sin <sid> y el proyecto 000 -> rc 1, sin cifra" "$RC ${OUT:-vacio}" "1 vacio"
P="$T/c/F-PROY-600"; mkdir -p "$P"; chmod 600 "$P"
chk F-PROY-600 "precondición: este usuario NO puede recorrer el proyecto (600)" "$([ -x "$P" ] && echo recorrible || echo no-recorrible)" no-recorrible
fsub "$P"; chk F-PROY-600 "sin <sid> y el proyecto 600 -> rc 1, sin cifra" "$RC ${OUT:-vacio}" "1 vacio"

echo "== Límites declarados: votan en falso y se MIDE que votan =="
C="$(fx L-ESPERA)"; printf '{"type":"assistant","uuid":"a2","message":{"content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"x"}}]}}\n' >> "$C/t.jsonl"
: > "$C/arbol"; tick "$C"; envejecer "$C" 100; tick "$C"
chk L-ESPERA "espera legítima con el turno bloqueado (tool_use en vuelo, sin hijos con CPU): vota rc 22 — LÍMITE" "$RC" 22

echo "== Candado: dos ticks a la vez =="
C="$(fx C-CONCURRENTE)"; tick "$C"; envejecer "$C" 100
( BW_BLOQUEA=1; export BW_BLOQUEA; tick "$C"; printf '%s\n' "$RC" > "$C/rc-A" ) &
pa=$!
for _ in $(seq 1 100); do [ -e "$C/dentro-A" ] && break; sleep 0.1; done
sleep 1.1
( tick "$C"; printf '%s\n' "$RC" > "$C/rc-B" ) &
pb=$!
sleep 1.5
s1="$(jq -r '.obs_ts' "$C/behavior/$CANAL.state")"
: > "$C/suelta-A"; wait "$pa"; wait "$pb"
fin="$(jq -r '.obs_ts' "$C/behavior/$CANAL.state")"
chk C-CONCURRENTE "un único sello" "$(sellos "$C")" 1
chk C-CONCURRENTE "los relojes persistidos no retroceden" "$([ "$fin" -ge "$s1" ] && echo si || echo "no ($fin < $s1)")" si
chk C-CONCURRENTE "los dos ticks votan rc 22" "$(cat "$C/rc-A" "$C/rc-B" | tr '\n' ' ')" "22 22 "
C="$(fx C-SERIE)"; tick "$C"; envejecer "$C" 100; tick "$C"; tick "$C"
chk C-CONCURRENTE "control: en serie, un sello" "$(sellos "$C")" 1

echo "== Sellador: rc 2 y rc 3 =="
C="$(fx SELLO-RC2)"; tick "$C"; envejecer "$C" 100; ROL='' tick "$C"
chk SELLO-RC2 "sellador rc 2 (sin rol): el detector devuelve igual rc 22" "$RC" 22
chk SELLO-RC2 "sellador rc 2 -> pendiente" "$(estado_tok "$C")" pendiente
chk SELLO-RC2 "sellador rc 2 -> 0 sellos" "$(sellos "$C")" 0
chk SELLO-RC2 "aviso por stderr" "$(grep -c 'queda PENDIENTE' "$C/err")" 1
m="$(jq -r '.tokens["PROGRESO-ESTANCADO"].marcador' "$C/behavior/$CANAL.state")"
tick "$C"
chk SELLO-RC2 "el tick siguiente reintenta el MISMO marcador y sella" "$(grep -c "\[marcador: $m\]" "$C/bus")" 1
chk SELLO-RC2 "tras el reintento: avisado" "$(estado_tok "$C")" avisado
C="$(fx SELLO-RC3)"; tick "$C"; envejecer "$C" 100; ROL='' tick "$C"
m="$(jq -r '.tokens["PROGRESO-ESTANCADO"].marcador' "$C/behavior/$CANAL.state")"
( env_caso "$C"; bash "$CEO/bus-sellar.sh" --marcador "$m" --rol coord-prueba --nota "previo" >/dev/null 2>&1 )
tick "$C"
chk SELLO-RC3 "rc 3 del MISMO marcador -> avisado" "$(estado_tok "$C")" avisado
chk SELLO-RC3 "rc 3 -> ningún sello nuevo" "$(grep -c "\[marcador: $m\]" "$C/bus")" 1

echo "== --report-only =="
C="$C_POS"; cp "$C/behavior/$CANAL.state" "$T/estado-antes"; cp "$C/cur/behavior-$CANAL.cursor" "$T/cursor-antes" 2>/dev/null || : > "$T/cursor-antes"
printf '%s [rol: otro] [marcador: %s-NUEVO]\n' "2026-09-24T00:00:00Z" "$CANAL" >> "$C/bus"
tick "$C" --report-only
chk REPORT-ONLY "el estado queda byte-idéntico" "$(cmp -s "$T/estado-antes" "$C/behavior/$CANAL.state" && echo igual || echo distinto)" igual
chk REPORT-ONLY "el cursor del bus no se mueve" "$(cmp -s "$T/cursor-antes" "$C/cur/behavior-$CANAL.cursor" && echo igual || echo distinto)" igual
chk REPORT-ONLY "no sella" "$(sellos "$C")" 1
chk REPORT-ONLY "lee el bus con --peek (ve el sello nuevo del canal)" "$(printf '%s' "$OUT" | grep -cE 'bus_last=[0-9]+$')" 1

C="$(fx REPORT-NUEVO)"; tick "$C" --report-only
chk REPORT-NUEVO "primera consulta --report-only (sin estado previo): rc 0" "$RC" 0
chk REPORT-NUEVO "no crea el directorio de estado ni el candado" "$([ -e "$C/behavior" ] && echo creado || echo nada)" nada
# bus-leer.sh --peek (talent-ceo, fuera de esta pieza) crea su directorio y su candado de lector aunque no mueve el cursor: se acota al cursor.
chk REPORT-NUEVO "no escribe ningún cursor del bus (ningún *.cursor bajo cur/)" "$(find "$C/cur" -name '*.cursor' 2>/dev/null | wc -l)" 0
tick "$C"
chk REPORT-NUEVO "control: un tick normal SÍ crea el directorio de estado" "$([ -e "$C/behavior/$CANAL.state" ] && echo creado || echo nada)" creado

echo "== bus_last: solo sellos del canal; ni VIGIA-* ni la nota =="
C="$(fx BUS-LAST)"
{ printf '2026-09-24T00:00:00Z [rol: coord-prueba] [marcador: VIGIA-PROGRESO-ESTANCADO-%s-1]\n' "$CANAL"
  printf '2026-09-24T00:00:01Z [rol: otro] [marcador: VIGIA-X-%s-2]\n' "$CANAL"
  printf '2026-09-24T00:00:02Z [rol: otro] [marcador: OTRO-1] cita [marcador: %s-FALSO]\n' "$CANAL"; } >> "$C/bus"
tick "$C"
chk BUS-LAST "un VIGIA-* (aunque sea del mismo marcador) y una cita en la nota no cuentan: bus_last=none" "$(printf '%s' "$OUT" | grep -c 'bus_last=none$')" 1
printf '2026-09-24T00:00:03Z [rol: otro] [marcador: %s-ESCALA-ABC-1]\n' "$CANAL" >> "$C/bus"; tick "$C"
chk BUS-LAST "control: un sello <canal>-… sí cuenta" "$(printf '%s' "$OUT" | grep -cE 'bus_last=[0-9]+$')" 1
tick "$C"
chk BUS-LAST "cursor propio: el sello ya leído persiste en el estado" "$(printf '%s' "$OUT" | grep -cE 'bus_last=[0-9]+$')" 1

echo "== Inventario de status.sh: 2 runs + 3 estados behavior -> «Corridas» lista 2 =="
C="$(fx INVENTARIO)"; mkdir -p "$C/runs/ABC-2"; printf '{"carril":"99","phase":"code"}\n' > "$C/runs/ABC-2/state.json"
mkdir -p "$C/behavior"; for n in 1 2 3; do printf '{"v":1}\n' > "$C/behavior/x$n.state"; done
corr() { ( env_caso "$C"; export PATH="$T/fakebin-incus:$PATH" TCO_DEV_CARRILES=46 TCO_AUDIT_CARRILES=''; bash "$SC/status.sh" 2>/dev/null ) \
  | sed 's/\x1b\[[0-9;]*m//g' | awk '/== Corridas ==/{f=1;next} /^==/{f=0} f && /^  ABC-/' | wc -l; }
mkdir -p "$T/fakebin-incus"; printf '#!/usr/bin/env bash\nexit 1\n' > "$T/fakebin-incus/incus"; chmod +x "$T/fakebin-incus/incus"
a="$(corr)"; tick "$C"; b="$(corr)"
chk INVENTARIO "«Corridas» lista 2 antes" "$a" 2
chk INVENTARIO "«Corridas» lista 2 después de un tick" "$b" 2
chk INVENTARIO "la columna behavior aparece en el censo" "$( ( env_caso "$C"; export PATH="$T/fakebin-incus:$PATH" TCO_DEV_CARRILES=46 TCO_AUDIT_CARRILES=''; bash "$SC/status.sh" 2>/dev/null ) | grep -c 'behavior: ')" 1
( env_caso "$C"; export PATH="$T/fakebin-incus:$PATH" TCO_DEV_CARRILES=46 TCO_AUDIT_CARRILES=''; bash "$SC/status.sh" >/dev/null 2>&1 ); src=$?
( env_caso "$C"; export PATH="$T/fakebin-incus:$PATH" TCO_DEV_CARRILES=46 TCO_AUDIT_CARRILES='' TCO_BEHAVIOR_WATCH=0; bash "$SC/status.sh" >/dev/null 2>&1 ); src0=$?
chk INVENTARIO "el rc del censo no cambia por la columna" "$src" "$src0"

echo "== run-state-write.sh =="
# status.sh aborta (rc 1) ante un directorio de runs/ sin state.json válido: aquí se retira el directorio entero de la fixture base.
C="$(fx W-KNOWN)"; rm -rf -- "${C:?}/runs/ABC-1"; rsw "$C" ABC-9 "$CANAL" active
chk W-KNOWN "claves EXACTAS" "$(jq -c keys "$C/runs/ABC-9/state.json")" '["carril","phase","ts"]'
chk W-KNOWN "carril y phase" "$(jq -r '.carril + " " + .phase' "$C/runs/ABC-9/state.json")" "$CANAL active"
tick "$C"; envejecer "$C" 100; tick "$C"
chk W-KNOWN "P2 vigente: active_run=ABC-9 run_reason=ok, vota" "$(printf '%s' "$OUT" | grep -c 'rc 22 .*active_run=ABC-9 run_reason=ok')" 1
chk W-KNOWN "status.sh lee un state.json de tres claves (fase:active)" "$( ( env_caso "$C"; export PATH="$T/fakebin-incus:$PATH" TCO_DEV_CARRILES='' TCO_AUDIT_CARRILES=''; bash "$SC/status.sh" 2>/dev/null ) | grep -c 'ABC-9 — fase:active')" 1
C="$(fx W-AUSENTE)"; rm -f -- "${C:?}/runs/ABC-1/state.json"; tick "$C"; envejecer "$C" 100; tick "$C"
chk W-AUSENTE "sin state.json del canal: active_run=no run_reason=no_state" "$(printf '%s' "$OUT" | grep -c 'active_run=no run_reason=no_state')" 1
chk W-AUSENTE "ningún token vota (rc 0) y 0 sellos" "$RC:$(sellos "$C")" "0:0"
C="$(fx W-CERRADO)"; rm -f -- "${C:?}/runs/ABC-1/state.json"; rsw "$C" ABC-9 "$CANAL" active; tick "$C"; envejecer "$C" 100
rsw "$C" ABC-9 "$CANAL" "done"; tick "$C"
chk W-CERRADO "cerrado con done: terminal y no vota con las tres condiciones verdaderas" "$RC $(printf '%s' "$OUT" | grep -o 'run_reason=[a-z_]*')" "0 run_reason=terminal"
chk W-CERRADO "0 sellos" "$(sellos "$C")" 0
# W-FAILSOFT: cada fallo -> stderr, rc 0, el anterior byte-idéntico y 0 temporales sueltos.
# Cada subcaso con su PROPIA fixture (un caso = un modo de fallo): uno que escriba de más no contamina al siguiente.
wprep() { # nombre -> C fresco con runs/ABC-5 en active y su copia en w-antes
  C="$(fx "W5-$1")"; rsw "$C" ABC-5 "$CANAL" active; cp "$C/runs/ABC-5/state.json" "$T/w-antes"
}
wfs() { # caso nombre comando...
  # stderr por SUSTITUCIÓN DE COMANDO: con `ulimit -f 0` (F-LLENO) no se podría escribir en un fichero, y un
  # `2> >(cat > f)` + `wait $!` NO espera a la sustitución de proceso en bash 5.2 (medido: 372/400 capturas
  # vacías), así que la aserción sobre stderr quedaba a merced de la carrera. `r` es el rc del subshell.
  local caso="$1" nom="$2" r err; shift 2
  err="$( { ( env_caso "$C"; "$@" ); } 2>&1 1>/dev/null )"; r=$?
  chk "$caso" "$nom: rc 0" "$r" 0
  chk "$caso" "$nom: stderr no vacío" "$([ -n "$err" ] && echo si || echo no)" si
  chk "$caso" "$nom: el state.json anterior byte-idéntico" "$(cmp -s "$T/w-antes" "$C/runs/ABC-5/state.json" && echo igual || echo distinto)" igual
  chk "$caso" "$nom: 0 temporales sueltos" "$(find "$C/runs" \( -name '.state.json.*' -o -name '.stg.*' \) | wc -l)" 0
}
wprep foo; wfs W-FAILSOFT "phase fuera del conjunto" bash "$SC/run-state-write.sh" ABC-5 "$CANAL" foo
wprep puntos; wfs W-FAILSOFT "TAL con ../" bash "$SC/run-state-write.sh" "ABC-5/../x" "$CANAL" active
wprep barra; wfs W-FAILSOFT "carril con /" bash "$SC/run-state-write.sh" ABC-5 "a/b" active
wprep lleno; wfs F-LLENO "la escritura del temporal falla (ulimit -f 0)" bash -c 'ulimit -f 0; exec bash "$0" ABC-5 "$1" "done"' "$SC/run-state-write.sh" "$CANAL"
wprep ro; chmod 500 "$C/runs/ABC-5"
wfs W-FAILSOFT "directorio no escribible" bash "$SC/run-state-write.sh" ABC-5 "$CANAL" "done"
chmod 700 "$C/runs/ABC-5"
wprep enlace; mv "$C/runs/ABC-5/state.json" "$C/runs/ABC-5/real.json"; ln -s real.json "$C/runs/ABC-5/state.json"; cp "$C/runs/ABC-5/real.json" "$T/w-antes"
wfs W-FAILSOFT "state.json enlace simbólico" bash "$SC/run-state-write.sh" ABC-5 "$CANAL" "done"
chk W-FAILSOFT "el enlace sigue siendo enlace" "$([ -L "$C/runs/ABC-5/state.json" ] && echo si || echo no)" si
C="$(fx W-INVALIDO)"; rsw "$C" ABC-5 "$CANAL" active; cp "$C/runs/ABC-5/state.json" "$T/w-antes"
wfs W-INVALIDO "el escritor deja un JSON a medias con rc 0" env TCO_RSW_WRITE_CMD="$T/bin/escribe-mitad" bash "$SC/run-state-write.sh" ABC-5 "$CANAL" "done"
chk W-INVALIDO "no se publica el JSON a medias" "$(jq -r .phase "$C/runs/ABC-5/state.json")" active
C="$(fx W-OTRO-TAL)"; rsw "$C" ABC-2 "$CANAL" active; cp "$C/runs/ABC-1/state.json" "$T/o1"; cp "$C/runs/ABC-2/state.json" "$T/o2"
( cd "$C/runs" && find . -type f | sort ) > "$T/o-antes"
rsw "$C" ABC-1 "$CANAL" "done"
chk W-OTRO-TAL "el otro TAL byte-idéntico" "$(cmp -s "$T/o2" "$C/runs/ABC-2/state.json" && echo igual || echo distinto)" igual
chk W-OTRO-TAL "control: el TAL pedido SÍ cambió" "$(cmp -s "$T/o1" "$C/runs/ABC-1/state.json" && echo igual || echo distinto)" distinto
chk W-OTRO-TAL "ningún fichero nuevo fuera de runs/ABC-1" "$( ( cd "$C/runs" && find . -type f | sort ) | diff - "$T/o-antes" | grep -c '^[<>]')" 0
C="$(fx W-ENUM)"; rsw "$C" ABC-3 "$CANAL" foo
chk W-ENUM "phase=foo no escribe" "$([ -e "$C/runs/ABC-3/state.json" ] && echo escrito || echo nada)" nada
C="$(fx W-CONCURRENTE)"; rsw "$C" ABC-4 "$CANAL" active
( env_caso "$C"; for _ in $(seq 1 200); do bash "$SC/run-state-write.sh" ABC-4 "$CANAL" active; done ) 2>/dev/null &
w1=$!
( env_caso "$C"; for _ in $(seq 1 200); do bash "$SC/run-state-write.sh" ABC-4 "$CANAL" "done"; done ) 2>/dev/null &
w2=$!
malas=0; lecturas=0
while kill -0 "$w1" 2>/dev/null || kill -0 "$w2" 2>/dev/null; do
  lecturas=$((lecturas+1))
  jq -e 'keys == ["carril","phase","ts"]' "$C/runs/ABC-4/state.json" >/dev/null 2>&1 || malas=$((malas+1))
done
wait "$w1" "$w2"
echo "  (W-CONCURRENTE: $lecturas lecturas)"
chk W-CONCURRENTE "0 lecturas que no sean un JSON completo de tres claves" "$malas" 0
chk W-CONCURRENTE "0 temporales al acabar" "$(find "$C/runs" -name '.state.json.*' | wc -l)" 0
chk W-CONCURRENTE "control: el lector leyó durante las escrituras (>= 10 lecturas)" "$([ "$lecturas" -ge 10 ] && echo si || echo no)" si
# Publicación atómica de la PRIMERA escritura de una issue: el censo (status.sh) lee mientras el escritor está a medias.
censo() { # -> CENSO_RC CENSO_N (corridas listadas)
  local o; o="$( ( env_caso "$C"; export PATH="$T/fakebin-incus:$PATH" TCO_DEV_CARRILES='' TCO_AUDIT_CARRILES=''; bash "$SC/status.sh" 2>/dev/null; echo "RC=$?" ) | sed 's/\x1b\[[0-9;]*m//g' )"
  CENSO_RC="$(printf '%s\n' "$o" | sed -n 's/^RC=//p')"; CENSO_N="$(printf '%s\n' "$o" | grep -c '^  ABC-')"
}
C="$(fx W-ATOMICO)"; censo; a_rc="$CENSO_RC"; a_n="$CENSO_N"
( env_caso "$C"; export TCO_RSW_WRITE_CMD="$T/bin/escribe-bloqueado"; bash "$SC/run-state-write.sh" ABC-6 "$CANAL" active ) 2>>"$T/rsw.err" &
wp=$!
for _ in $(seq 1 100); do [ -e "$C/dentro-W" ] && break; sleep 0.1; done
censo
chk W-ATOMICO "control: el escritor está a medias de la primera escritura" "$([ -e "$C/dentro-W" ] && echo si || echo no)" si
chk W-ATOMICO "durante la escritura el censo da el mismo rc que antes" "$CENSO_RC" "$a_rc"
chk W-ATOMICO "durante la escritura el censo lista las mismas corridas" "$CENSO_N" "$a_n"
: > "$C/suelta-W"; wait "$wp"; censo
chk W-ATOMICO "publicada: el censo lista una corrida más" "$CENSO_N" "$((a_n + 1))"
chk W-ATOMICO "0 restos de staging ni temporales" "$(find "$C/runs" \( -name '.state.json.*' -o -name '.stg.*' \) | wc -l)" 0
C="$(fx W-NUEVO-FALLA)"
err="$( { ( env_caso "$C"; bash -c 'ulimit -f 0; exec bash "$0" ABC-8 "$1" active' "$SC/run-state-write.sh" "$CANAL" ); } 2>&1 1>/dev/null )"; r=$?
chk W-NUEVO-FALLA "la escritura falla en una issue NUEVA: rc 0 y aviso por stderr" "$r $([ -n "$err" ] && echo aviso || echo mudo)" "0 aviso"
chk W-NUEVO-FALLA "no deja ningún directorio de la issue" "$([ -e "$C/runs/ABC-8" ] && echo existe || echo nada)" nada
chk W-NUEVO-FALLA "0 restos de staging ni temporales" "$(find "$C/runs" \( -name '.state.json.*' -o -name '.stg.*' \) | wc -l)" 0
C="$(fx W-RUNS-INTACTO)"; mkdir -p "$C/runs/ABC-2"; printf '{"carril":"otro","phase":"code"}\n' > "$C/runs/ABC-2/state.json"
huella() { ( cd "$1/runs" && find . -type f -print0 | sort -z | xargs -0 sha256sum ); }
h0="$(huella "$C")"; tick "$C"; envejecer "$C" 100; tick "$C"; tick "$C" --report-only; h1="$(huella "$C")"
chk W-RUNS-INTACTO "tres ticks del detector: la huella de \$TCO_RUNS_DIR igual" "$([ "$h0" = "$h1" ] && echo igual || echo distinto)" igual
chk W-RUNS-INTACTO "control: los ticks corrieron (rc 22 en el segundo)" "$(sellos "$C")" 1
chk W-RUNS-INTACTO "el detector no llama al escritor (grep = 0)" "$(grep -c 'run-state-write' "$SC/behavior-watch.sh")" 0

echo "== C11: LOOP (rc 20) y RUNTIME-EXCESIVO (rc 21) no existen =="
chk C11 "control: los ticks de todo el selftest incluyen al menos un rc 22" "$([ "$(grep -c '^22$' "$T/rcs")" -ge 1 ] && echo si || echo no)" si
chk C11 "ningún tick del selftest devolvió rc 20 ni rc 21" "$(grep -cE '^(20|21)$' "$T/rcs")" 0
chk C11 "ninguna línea de salida nombra LOOP ni RUNTIME-EXCESIVO" "$(grep -cE 'LOOP|RUNTIME-EXCESIVO' "$T/salidas")" 0
chk C11 "el detector no asigna ni devuelve rc 20/21 (rc=2[01], return 2[01])" "$(grep -cE 'rc=2[01]|return 2[01]' "$SC/behavior-watch.sh")" 0

TOTAL=$((PASS+FAIL+SKIP))
printf '\nPASS=%s FAIL=%s SKIP=%s TOTAL=%s TOTAL_ESPERADO=%s\n' "$PASS" "$FAIL" "$SKIP" "$TOTAL" "$TOTAL_ESPERADO"
[ "$FAIL" -eq 0 ] && [ "$TOTAL" -eq "$TOTAL_ESPERADO" ] || exit 1
exit 0
