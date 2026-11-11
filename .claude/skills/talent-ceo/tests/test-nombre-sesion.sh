#!/usr/bin/env bash
# test-nombre-sesion.sh — Tests HERMÉTICOS de nombre-sesion.sh (issue 8571).
#
# Sin red, sin tmux real y sin leer los procesos de la máquina: `ps` es un doble en un PATH
# temporal que sirve tablas y líneas de comandos de ficheros del fixture. Los nombres y modelos son
# sintéticos.
#
# ── MÉTODO ─────────────────────────────────────────────────────────────────────────────────────
# Un verde de control por rol y un negativo por cada fila del contrato (C2-C7). Dos cierres:
#  · el señuelo (proceso que MENCIONA «claude --name ceo» sin SER claude) se prueba con la
#    herramienta real y con un MUTANTE al que se le quita la selección por `comm`: el mutante
#    debe aceptar el señuelo, o el caso no discrimina nada;
#  · el argv que lee la herramienta es el del pid ya elegido, y nada más del argv sale a la salida.
#
# ── LA SUITE SE AFIRMA A SÍ MISMA ──────────────────────────────────────────────────────────────
# Al final exige que ejecutados == TOTAL_ESPERADO.
set -uo pipefail
umask 022
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="$ROOT/scripts/nombre-sesion.sh"

TOTAL_ESPERADO=76
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FXBIN="$T/bin"; mkdir -p "$FXBIN"

# Doble de ps: solo sirve la tabla de procesos (-e -o pid=,ppid=,comm=); el argv NO se lee con ps (aplana
# los límites de los argumentos) sino de una raíz /proc de fixture (TF_PROC_ROOT) con cmdline separado por NUL.
# Cada llamada a ps queda en $PSLOG. PSFALLA fuerza rc 1.
cat > "$FXBIN/ps" <<'EOF'
#!/usr/bin/env bash
[ -z "${PSFALLA-}" ] || exit 1
printf '%s\n' "$*" >> "$PSLOG"
case "$*" in
  '-e -o pid=,ppid=,comm=') cat "$PSTABLA" ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$FXBIN/ps"
export PSTABLA="$T/tabla" PSLOG="$T/pslog" TF_PROC_ROOT="$T/proc"

# fx <tabla> <argv>: líneas separadas por saltos de línea reales; cada línea de argv es «pid palabras…»
# y se escribe como cmdline NUL-separado. Para límites exactos de argumento, argv_exacto.
fx() {
  local linea pid resto palabras
  printf '%s\n' "$1" > "$PSTABLA"; : > "$PSLOG"; unset PSFALLA
  rm -rf "${T:?}/proc"; mkdir -p "$TF_PROC_ROOT"
  while IFS= read -r linea; do
    [ -n "$linea" ] || continue
    pid="${linea%% *}"; resto="${linea#* }"
    mkdir -p "$TF_PROC_ROOT/$pid"
    read -r -a palabras <<< "$resto"
    printf '%s\0' "${palabras[@]}" > "$TF_PROC_ROOT/$pid/cmdline"
  done <<< "$2"
}
# argv_exacto <pid> <arg>…: el cmdline con los límites de argumento tal cual (un argumento puede llevar espacios).
argv_exacto() { local pid="$1"; shift; mkdir -p "$TF_PROC_ROOT/$pid"; printf '%s\0' "$@" > "$TF_PROC_ROOT/$pid/cmdline"; }
SALIDAS="$T/salidas"; : > "$SALIDAS"
# ns <script> args… → OUT, ERR, RC; todo lo emitido se acumula en $SALIDAS (caso «no se imprime argv»).
ns() {
  local script="$1"; shift
  OUT="$(PATH="$FXBIN:$PATH" bash "$script" "$@" 2> "$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
  printf '%s\n%s\n' "$OUT" "$ERR" >> "$SALIDAS"
}

CLAUDE_ARGV='--dangerously-skip-permissions --model modelo-ejemplo'
TABLA_BASE=$'100 1 bash\n101 100 claude'

printf '== control positivo: nombre por rol ==\n'
fx "$TABLA_BASE" "101 claude --dangerously-skip-permissions --name ceo --model modelo-ejemplo"
ns "$NS" --observado 100
assert_eq "[C1] --observado ceo: rc 0 y solo el nombre" "0|ceo" "$RC|$OUT"
fx "$TABLA_BASE" "101 claude --dangerously-skip-permissions --name torre-c1 --model modelo-ejemplo"
ns "$NS" --observado 100
assert_eq "[C1] --observado torre-c1" "0|torre-c1" "$RC|$OUT"
fx "$TABLA_BASE" "101 claude --dangerously-skip-permissions --name m1 --model modelo-ejemplo"
ns "$NS" --observado 100
assert_eq "[C1] --observado m1" "0|m1" "$RC|$OUT"
fx "$TABLA_BASE" "101 claude $CLAUDE_ARGV --name=ceo"
ns "$NS" --observado 100
assert_eq "[R2b] --name=valor en un único argumento NO es la opción de nombre: SIN-NOMBRE" "1|SIN-NOMBRE|" "$RC|$ERR|$OUT"
fx "$TABLA_BASE" "101 claude -n ceo $CLAUDE_ARGV"
ns "$NS" --observado 100
assert_eq "forma corta -n valor" "0|ceo" "$RC|$OUT"
fx "$TABLA_BASE" "101 claude --dangerously-skip-permissions --name ceo --model modelo-ejemplo"
ns "$NS" --verificar ceo 100
assert_eq "--verificar igual: rc 0 y línea OK" "0|OK nombre ceo" "$RC|$OUT"

printf '== C5: solo el valor tras --name, nunca el resto del argv ==\n'
fx "$TABLA_BASE" "101 claude --dangerously-skip-permissions --name ceo --model modelo-ejemplo"
ns "$NS" --observado 100
assert_eq "[C5] la salida no contiene modelo ni flags" "0" "$(printf '%s\n%s\n' "$OUT" "$ERR" | grep -Ec 'model|dangerously')"
ns "$NS" --verificar ceo 100
assert_eq "[C5] --verificar tampoco vuelca el argv" "0" "$(printf '%s\n%s\n' "$OUT" "$ERR" | grep -Ec 'model|dangerously')"

printf '== C2: sesión viva sin nombre ==\n'
fx "$TABLA_BASE" "101 claude $CLAUDE_ARGV"
ns "$NS" --observado 100
assert_eq "[C2] sin --name: rc 1 y SIN-NOMBRE" "1|SIN-NOMBRE|" "$RC|$ERR|$OUT"
ns "$NS" --verificar torre-c1 100
assert_eq "[C2] --verificar sin nombre: rc 1, SIN-NOMBRE y FALLA" "1|SIN-NOMBRE|FALLA nombre torre-c1" "$RC|$ERR|$OUT"

printf '== C3: nombre distinto ==\n'
fx "$TABLA_BASE" "101 claude --dangerously-skip-permissions --name otro --model modelo-ejemplo"
ns "$NS" --verificar ceo 100
assert_eq "[C3] distinto: rc 1 y FALLA" "1|FALLA nombre ceo" "$RC|$OUT"
assert_eq "[C3] stderr da esperado y observado" "NOMBRE-DISTINTO esperado=ceo observado=otro" "$ERR"

printf '== C4: ps no responde o argv ilegible: nunca verde ==\n'
fx "$TABLA_BASE" "101 claude --name ceo"
export PSFALLA=1
ns "$NS" --verificar ceo 100
assert_eq "[C4] ps falla: rc 2, NOVERIF" "2|NOVERIF nombre ceo" "$RC|$OUT"
assert_eq "[C4] ps falla: stderr NO-VERIFICABLE" "NO-VERIFICABLE" "$ERR"
ns "$NS" --observado 100
assert_eq "[C4] --observado con ps caído: rc 2 y nada en stdout" "2|" "$RC|$OUT"
fx "$TABLA_BASE" "101 claude --name ceo"; : > "$PSTABLA"
ns "$NS" --verificar ceo 100
assert_eq "[C4] ps sin salida: rc 2" "2|NOVERIF nombre ceo" "$RC|$OUT"
fx "$TABLA_BASE" "101 claude --name ceo"; rm -f "$TF_PROC_ROOT/101/cmdline"; mkdir "$TF_PROC_ROOT/101/cmdline"
ns "$NS" --verificar ceo 100
assert_eq "[C4] argv del pid elegido ilegible (cmdline no es un fichero): rc 2" "2|NOVERIF nombre ceo" "$RC|$OUT"
fx "$TABLA_BASE" "999 claude --name ceo"
ns "$NS" --verificar ceo 100
assert_eq "[C4] el pid elegido desapareció antes de leer su argv: rc 2" "2|NOVERIF nombre ceo" "$RC|$OUT"

printf '== C6: valor fuera de [A-Za-z0-9_-]{1,64} o flag sin valor ==\n'
fx "$TABLA_BASE" "101 claude --name ce.o --model x"
ns "$NS" --observado 100
assert_eq "[C6] punto en el valor: NOMBRE-INVALIDO" "1|NOMBRE-INVALIDO|" "$RC|$ERR|$OUT"
fx "$TABLA_BASE" "101 claude --name ce;o --model x"
ns "$NS" --observado 100
assert_eq "[C6] punto y coma en el valor: NOMBRE-INVALIDO" "1|NOMBRE-INVALIDO" "$RC|$ERR"
fx "$TABLA_BASE" "101 claude --name $(printf 'a%.0s' $(seq 1 65)) --model x"
ns "$NS" --observado 100
assert_eq "[C6] 65 caracteres: NOMBRE-INVALIDO" "1|NOMBRE-INVALIDO" "$RC|$ERR"
fx "$TABLA_BASE" "101 claude --name $(printf 'a%.0s' $(seq 1 64)) --model x"
ns "$NS" --observado 100
assert_eq "[C6] 64 caracteres: válido" "0" "$RC"
fx "$TABLA_BASE" "101 claude --model x --name"
ns "$NS" --observado 100
assert_eq "[C6] --name al final, sin valor: SIN-NOMBRE" "1|SIN-NOMBRE" "$RC|$ERR"
fx "$TABLA_BASE" "101 claude --name --model x"
ns "$NS" --observado 100
assert_eq "[C6] --name seguido de otro flag: SIN-NOMBRE" "1|SIN-NOMBRE" "$RC|$ERR"
fx "$TABLA_BASE" "101 claude --name= --model x"
ns "$NS" --observado 100
assert_eq "[C6] --name= vacío: SIN-NOMBRE" "1|SIN-NOMBRE" "$RC|$ERR"

printf '== C7: manda el ejecutable (comm), no la línea de comandos ==\n'
SENUELO_ARGV=$'100 bash -c claude --dangerously-skip-permissions --name ceo --model modelo-ejemplo\n101 bash -c claude --dangerously-skip-permissions --name ceo --model modelo-ejemplo'
fx $'100 1 bash\n101 100 bash' "$SENUELO_ARGV"
ns "$NS" --verificar ceo 100
assert_eq "[C7] comm=bash cuyo argv menciona claude --name ceo: SIN-PROCESO" "1|SIN-PROCESO|FALLA nombre ceo" "$RC|$ERR|$OUT"
fx $'100 1 bash\n101 100 claude-code' "101 claude-code --name ceo"
ns "$NS" --verificar ceo 100
assert_eq "[C7] mutante «comm distinto» (claude-code): SIN-PROCESO" "1|SIN-PROCESO" "$RC|$ERR"
fx $'100 1 bash\n101 100 node' "101 node /usr/lib/claude --name ceo"
ns "$NS" --verificar ceo 100
assert_eq "[C7] comm=node con claude y --name en el argv: SIN-PROCESO" "1|SIN-PROCESO" "$RC|$ERR"
fx $'100 1 bash\n101 100 claude-x' "101 claude --name ceo"
ns "$NS" --observado 100
assert_eq "[C7] comm que solo empieza por claude: SIN-PROCESO" "1|SIN-PROCESO" "$RC|$ERR"
assert_eq "[M1] ps no se usa para leer el argv (aplana los límites de los argumentos)" "0" "$(grep -c -- '-o args=' "$PSLOG")"

# Mutante: se quita la selección por comm (cualquier proceso vale). El señuelo debe colarse.
MUT="$T/nombre-sesion-mutante.sh"
sed 's/if (com\[p\] != "claude") continue/if (com[p] == "") continue/' "$NS" > "$MUT"
assert_eq "el mutante difiere de la herramienta real" "1" "$(cmp -s "$NS" "$MUT"; echo $?)"
fx $'100 1 bash\n101 100 bash' "$SENUELO_ARGV"
ns "$MUT" --verificar ceo 100
assert_eq "mutante sin comm acepta el señuelo (rc 0): el caso C7 discrimina" "0|OK nombre ceo" "$RC|$OUT"
ns "$NS" --verificar ceo 100
assert_eq "la herramienta real rechaza el mismo señuelo" "1" "$RC"

printf '== el pane manda: descendientes, profundidad y alcance ==\n'
fx $'100 1 bash\n101 100 python3\n102 101 claude' "102 claude --name m1 --model x"
ns "$NS" --observado 100
assert_eq "claude nieto del pane: encontrado" "0|m1" "$RC|$OUT"
fx $'100 1 claude\n200 1 bash' "100 claude --name ceo --model x"
ns "$NS" --observado 100
assert_eq "el propio pid del pane es claude: encontrado" "0|ceo" "$RC|$OUT"
fx $'100 1 bash\n200 1 claude' "200 claude --name ceo --model x"
ns "$NS" --observado 100
assert_eq "un claude fuera del árbol del pane no cuenta: SIN-PROCESO" "1|SIN-PROCESO" "$RC|$ERR"
fx $'100 1 bash\n101 100 claude\n102 101 claude' $'101 claude --name torre-c1 --model x\n102 claude -p hola'
rm -f "$TF_PROC_ROOT/102/cmdline"; mkdir "$TF_PROC_ROOT/102/cmdline"
ns "$NS" --observado 100
assert_eq "dos claude: manda el más cercano a la raíz" "0|torre-c1" "$RC|$OUT"
assert_eq "solo se lee el argv del pid elegido (el otro, ilegible, no importa)" "0" "$(grep -c -- '-o args=' "$PSLOG")"
fx $'100 1 bash\n300 1 bash\n301 300 claude' $'301 claude --name m1 --model x'
ns "$NS" --observado 100 300
assert_eq "varios pids de pane: se busca bajo todos" "0|m1" "$RC|$OUT"

printf '== M1: los límites de los argumentos se conservan (cmdline separado por NUL) ==\n'
fx "$TABLA_BASE" ""
argv_exacto 101 claude --name 'ceo otro' --model modelo-ejemplo
ns "$NS" --verificar ceo 100
assert_eq "[M1] --name con valor «ceo otro»: NOMBRE-INVALIDO, no se acredita «ceo»" "1|NOMBRE-INVALIDO|FALLA nombre ceo" "$RC|$ERR|$OUT"
argv_exacto 101 claude -n 'ceo otro'
ns "$NS" --observado 100
assert_eq "[M1] -n con valor «ceo otro»: NOMBRE-INVALIDO" "1|NOMBRE-INVALIDO" "$RC|$ERR"
argv_exacto 101 claude '--name=ceo otro'
ns "$NS" --observado 100
assert_eq "[M1] --name=«ceo otro» en un único argumento: SIN-NOMBRE (no es la opción)" "1|SIN-NOMBRE" "$RC|$ERR"
argv_exacto 101 claude --name $'ceo\notro'
ns "$NS" --observado 100
assert_eq "[M1] valor con salto de línea: NOMBRE-INVALIDO" "1|NOMBRE-INVALIDO" "$RC|$ERR"
argv_exacto 101 claude -p 'explica --name ceo'
ns "$NS" --verificar ceo 100
assert_eq "[M1] --name dentro de un prompt no es opción: SIN-NOMBRE" "1|SIN-NOMBRE|FALLA nombre ceo" "$RC|$ERR|$OUT"
argv_exacto 101 claude -p 'explica -n ceo'
ns "$NS" --observado 100
assert_eq "[M1] -n dentro de un prompt no es opción: SIN-NOMBRE" "1|SIN-NOMBRE" "$RC|$ERR"
argv_exacto 101 claude -- --name ceo
ns "$NS" --observado 100
assert_eq "[M1] tras -- nada es opción: SIN-NOMBRE" "1|SIN-NOMBRE" "$RC|$ERR"
argv_exacto 101 claude --name ''
ns "$NS" --observado 100
assert_eq "[M1] valor vacío (argumento vacío): SIN-NOMBRE" "1|SIN-NOMBRE" "$RC|$ERR"
argv_exacto 101 claude -nceo
ns "$NS" --observado 100
assert_eq "[M1] -nceo pegado no es la forma reconocida: SIN-NOMBRE" "1|SIN-NOMBRE" "$RC|$ERR"
argv_exacto 101 claude --name ceo --model modelo-ejemplo
ns "$NS" --verificar ceo 100
assert_eq "[M1] control: argumentos exactos, --name ceo: OK" "0|OK nombre ceo" "$RC|$OUT"
: > "$TF_PROC_ROOT/101/cmdline"
ns "$NS" --verificar ceo 100
assert_eq "[M1] cmdline vacío: rc 2 (no verificable), nunca verde" "2|NOVERIF nombre ceo" "$RC|$OUT"

printf '== M1-R2a: TF_PROC_ROOT solo bajo el directorio temporal ==\n'
# Prefijo permitido: TMPDIR=$PREF. Dentro hay un fixture válido; FUERA de $PREF ($T/proc, un enlace y un «..»)
# hay otros cmdline igualmente válidos: así cada rechazo se debe a la guarda y no a que falte el fichero.
PREF="$T/pref"; mkdir -p "$PREF/proc/101" "$PREF/otro" "$PREF/101"
printf '%s\0' claude --name ceo > "$PREF/proc/101/cmdline"
printf '%s\0' claude --name ceo > "$PREF/101/cmdline"
fx "$TABLA_BASE" ""
argv_exacto 101 claude --name ceo
ln -s "$T/proc" "$PREF/enlace"
# nsr <TMPDIR> <TF_PROC_ROOT> <cwd> args… → OUT, ERR, RC
nsr() {
  local tmpd="$1" raiz="$2" cwd="$3"; shift 3
  OUT="$(cd "$cwd" && env TMPDIR="$tmpd" TF_PROC_ROOT="$raiz" PATH="$FXBIN:$PATH" bash "$NS" "$@" 2> "$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
  printf '%s\n%s\n' "$OUT" "$ERR" >> "$SALIDAS"
}
RECHAZO="2|RAIZ-PROC-NO-PERMITIDA|NOVERIF nombre ceo"
nsr "$PREF" "$PREF/proc" "$T" --verificar ceo 100
assert_eq "[R2a] fixture estrictamente dentro del prefijo permitido: OK" "0|OK nombre ceo" "$RC|$OUT"
nsr "$PREF/otro" "$PREF/proc" "$T" --verificar ceo 100
assert_eq "[R2a] raíz fuera del prefijo (TMPDIR distinto) aunque su cmdline sea válido: rechazada" "$RECHAZO" "$RC|$ERR|$OUT"
nsr "$PREF" / "$T" --verificar ceo 100
assert_eq "[R2a] raíz «/»: rechazada" "$RECHAZO" "$RC|$ERR|$OUT"
nsr "$PREF" /proc "$T" --verificar ceo 100
assert_eq "[R2a] raíz «/proc» pedida por variable: rechazada" "$RECHAZO" "$RC|$ERR|$OUT"
nsr "$PREF" proc "$PREF" --verificar ceo 100
assert_eq "[R2a] raíz relativa (existe desde el cwd, con cmdline válido): rechazada" "$RECHAZO" "$RC|$ERR|$OUT"
nsr "$PREF" "$PREF/proc/../../proc" "$T" --verificar ceo 100
assert_eq "[R2a] escape por «..» hacia un fixture válido fuera del prefijo: rechazado" "$RECHAZO" "$RC|$ERR|$OUT"
nsr "$PREF" "$PREF/enlace" "$T" --verificar ceo 100
assert_eq "[R2a] enlace dentro del prefijo que apunta fuera: rechazado" "$RECHAZO" "$RC|$ERR|$OUT"
nsr "$PREF" "$PREF" "$T" --verificar ceo 100
assert_eq "[R2a] raíz igual al propio prefijo (con cmdline válido debajo): rechazada" "$RECHAZO" "$RC|$ERR|$OUT"
nsr "$PREF" "" "$T" --verificar ceo 100
assert_eq "[R2a] TF_PROC_ROOT definida pero vacía: rechazada" "$RECHAZO" "$RC|$ERR|$OUT"

printf '== M1-R2b: un cmdline sin NUL final es un registro incompleto (rc 2, antes de buscar el nombre) ==\n'
# Bytes exactos: el último fragmento sin NUL puede ser una lectura truncada de un valor más largo.
fx "$TABLA_BASE" ""
mkdir -p "$TF_PROC_ROOT/101"
printf 'claude\0--name\0ceo\0' > "$TF_PROC_ROOT/101/cmdline"
ns "$NS" --verificar ceo 100
assert_eq "[R2b] control: cmdline completo con NUL final: OK" "0|OK nombre ceo" "$RC|$OUT"
printf 'claude\0--name\0ceo' > "$TF_PROC_ROOT/101/cmdline"
ns "$NS" --verificar ceo 100
assert_eq "[R2b] valor de --name sin NUL final (¿truncado?): rc 2, NO-VERIFICABLE" "2|NO-VERIFICABLE|NOVERIF nombre ceo" "$RC|$ERR|$OUT"
printf 'claude\0-n\0ceo' > "$TF_PROC_ROOT/101/cmdline"
ns "$NS" --verificar ceo 100
assert_eq "[R2b] valor de -n sin NUL final: rc 2, NO-VERIFICABLE" "2|NO-VERIFICABLE|NOVERIF nombre ceo" "$RC|$ERR|$OUT"
printf 'claude\0--name=ceo' > "$TF_PROC_ROOT/101/cmdline"
ns "$NS" --verificar ceo 100
assert_eq "[R2b] --name=ceo sin NUL final: rc 2 (incompleto, antes que SIN-NOMBRE)" "2|NO-VERIFICABLE|NOVERIF nombre ceo" "$RC|$ERR|$OUT"
printf 'claude --name ceo' > "$TF_PROC_ROOT/101/cmdline"
ns "$NS" --verificar ceo 100
assert_eq "[R2b] representación plana sin ningún NUL: rc 2, no SIN-NOMBRE" "2|NO-VERIFICABLE|NOVERIF nombre ceo" "$RC|$ERR|$OUT"

printf '== proceso real: ps y /proc de verdad ==\n'
# Un script llamado claude (shebang directo: su comm es «claude») bloqueado en un read sin hijos; el pane es él mismo.
cat > "$FXBIN/claude" <<'EOF'
#!/bin/bash
exec 3<> "$3"
read -r -t 20 -u 3 _
EOF
chmod 755 "$FXBIN/claude"
mkfifo "$T/fifo"
"$FXBIN/claude" --name ceo "$T/fifo" & REAL_PID=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do [ "$(cat "/proc/$REAL_PID/comm" 2>/dev/null)" = claude ] && break; sleep 0.3; done
OUT="$(env -u TF_PROC_ROOT bash "$NS" --verificar ceo "$REAL_PID" 2>"$T/err")"; RC=$?
assert_eq "[real] claude real con --name ceo en /proc: OK" "0|OK nombre ceo" "$RC|$OUT"
OUT="$(env -u TF_PROC_ROOT bash "$NS" --verificar torre-c1 "$REAL_PID" 2>"$T/err")"; RC=$?
assert_eq "[real] el mismo proceso contra otro nombre: rc 1" "1|FALLA nombre torre-c1" "$RC|$OUT"
kill "$REAL_PID" 2>/dev/null
wait "$REAL_PID" 2>/dev/null

printf '== uso incorrecto: rc 2 sin tocar ps ==\n'
fx "$TABLA_BASE" "101 claude --name ceo"
ns "$NS" --verificar ceo
assert_eq "--verificar sin pid: rc 2" "2" "$RC"
ns "$NS" --observado abc
assert_eq "pid no numérico: rc 2" "2" "$RC"
ns "$NS" --verificar $'ceo\notro' 100
assert_eq "[m1] esperado con salto de línea («ceo» + «otro»): rc 2 y nada en stdout" "2|" "$RC|$OUT"
ns "$NS" --verificar ceo $'100\notro'
assert_eq "[m1] pid con salto de línea («100» + «otro»): rc 2 y nada en stdout" "2|" "$RC|$OUT"
ns "$NS" --observado $'100\notro'
assert_eq "[m1] --observado con pid multilínea: rc 2" "2" "$RC"
ns "$NS" --verificar ceo 100 $'101\n102'
assert_eq "[m1] un pid válido y otro multilínea: rc 2" "2" "$RC"
ns "$NS" --verificar 'ce o' 100
assert_eq "esperado fuera de charset: rc 2" "2" "$RC"
ns "$NS"
assert_eq "sin modo: rc 2" "2" "$RC"
assert_eq "el uso incorrecto no llamó a ps" "0" "$(wc -l < "$PSLOG" | tr -d ' ')"

printf '== invariantes de salida y de base ==\n'
assert_eq "ninguna salida de la suite volcó modelo, flags o ruta del argv" "0" \
  "$(grep -Ec 'dangerously|modelo-ejemplo|/usr/lib' "$SALIDAS")"

printf '\n== %d ok, %d FAIL (esperados: %d casos) ==\n' "$PASS" "$FAIL" "$TOTAL_ESPERADO"
rc=0
[ "$FAIL" -eq 0 ] || { echo "FAIL: hubo casos rojos"; rc=1; }
[ $((PASS + FAIL)) -eq "$TOTAL_ESPERADO" ] || {
  echo "FAIL: casos contabilizados $((PASS + FAIL)) != TOTAL_ESPERADO $TOTAL_ESPERADO (¿desaparecio un caso?)"; rc=1; }
exit "$rc"
