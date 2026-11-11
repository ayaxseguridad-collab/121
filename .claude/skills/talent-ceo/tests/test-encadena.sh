#!/usr/bin/env bash
# test-encadena.sh — Tests HERMÉTICOS del helper muestra_sublog de run-tests.sh (issue 8936).
# run-tests.sh encadena suites propias y de cada una dejaba solo la cola de tres líneas: si una enrojecía
# no decía CUAL caso. El helper imprime además cada línea `  FAIL ...` cuando rc != 0. Aquí se EXTRAE de
# run-tests.sh entre sus marcadores (se prueba el código real) y se ejecuta sobre un sublog de fixture, sobre
# una suite falsa que falla de verdad y sobre un MUTANTE (solo la cola), que debe dejar de mostrar el caso.
# Al final exige que ejecutados == TOTAL_ESPERADO.
set -uo pipefail
umask 022
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT="$HERE/run-tests.sh"

TOTAL_ESPERADO=9
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
SRC="$(sed -n '/^# >>> encadena-inicio$/,/^# <<< encadena-fin$/p' "$RT")"
eval "$SRC"
assert_eq "[enc-a] run-tests.sh trae UN bloque marcado que define muestra_sublog" "1|1|muestra_sublog" \
  "$(grep -c '^# >>> encadena-inicio$' "$RT")|$(grep -c '^# <<< encadena-fin$' "$RT")|$(declare -F muestra_sublog)"

# Sublog de fixture: los dos FAIL quedan FUERA de la cola de tres líneas.
LOG="$T/sub.log"
printf '%s\n' '  ok   [f-1] uno' '  FAIL [f-2] caso rojo uno (esperado=0 obtenido=1)' '  ok   [f-3] tres' '  FAIL [f-4] caso rojo dos' \
  '  ok   [f-5] cinco' '' '== 3 ok, 2 FAIL (esperados: 5 casos) ==' 'FAIL: hubo casos rojos' > "$LOG"
assert_eq "[enc-b] control: la cola de tres lineas SOLA no contiene ningun caso rojo" "0" "$(tail -n 3 "$LOG" | grep -c 'caso rojo')"
OUT="$(muestra_sublog "$LOG" 1)"
assert_eq "[enc-c1] rc 1: salen COMPLETAS las dos lineas FAIL, y solo ellas" \
  "    !   FAIL [f-2] caso rojo uno (esperado=0 obtenido=1)|    !   FAIL [f-4] caso rojo dos" "$(printf '%s\n' "$OUT" | grep '^    ! ' | paste -sd'|')"
assert_eq "[enc-c2] rc 1: la cola de tres lineas sigue saliendo" "$(tail -n 3 "$LOG" | sed 's/^/    | /')" "$(printf '%s\n' "$OUT" | grep '^    | ')"
assert_eq "[enc-d] rc 0: la salida es EXACTAMENTE la cola prefijada de siempre" "$(tail -n 3 "$LOG" | sed 's/^/    | /')" "$(muestra_sublog "$LOG" 0)"

printf '%s\n' '#!/usr/bin/env bash' 'printf "  ok   [x-1] uno\n  FAIL [x-2] el caso interno que antes se perdia\n"' \
  'printf "  ok   [x-3] tres\n  ok   [x-4] cuatro\n  ok   [x-5] cinco\n\n== 4 ok, 1 FAIL (esperados: 5 casos) ==\n"' 'exit 1' > "$T/falsa.sh"
bash "$T/falsa.sh" > "$T/falsa.log" 2>&1; rc_f=$?
assert_eq "[enc-e] suite falsa que falla (rc 1) encadenada: el log muestra su caso interno" "1|1" \
  "$rc_f|$(muestra_sublog "$T/falsa.log" "$rc_f" | grep -cxF '    !   FAIL [x-2] el caso interno que antes se perdia')"

SRC_MUT="$(printf '%s\n' "$SRC" | grep -v "grep -E '^  FAIL '")"
assert_eq "[enc-f] mutante (solo la cola): se aplico y NO muestra el caso rojo" "1|0" \
  "$([ "$SRC" != "$SRC_MUT" ] && echo 1 || echo 0)|$( eval "$SRC_MUT"; muestra_sublog "$LOG" 1 | grep -c 'caso rojo' )"

assert_eq "[enc-g1] fuera del helper no queda ningun 'tail -n 3' suelto en run-tests.sh" "0" "$(grep -c '^tail -n 3 ' "$RT")"
# shellcheck disable=SC2016  # el $T de los patrones es LITERAL: se busca el texto de run-tests.sh
assert_eq "[enc-g2] los seis encadenados de siempre y este usan el helper, en este orden" \
  "supervision nombre-sesion runners-al-dia vigias medidores desvio encadena seguridad-doctor" \
  "$(grep -o '^muestra_sublog "\$T/[a-z-]*\.log"' "$RT" | sed 's/^muestra_sublog "\$T\///; s/\.log"$//' | paste -sd' ')"

printf '\n== %d ok, %d FAIL (esperados: %d casos) ==\n' "$PASS" "$FAIL" "$TOTAL_ESPERADO"
rc=0
[ "$FAIL" -eq 0 ] || { echo "FAIL: hubo casos rojos"; rc=1; }
[ $((PASS + FAIL)) -eq "$TOTAL_ESPERADO" ] || {
  echo "FAIL: casos contabilizados $((PASS + FAIL)) != TOTAL_ESPERADO $TOTAL_ESPERADO (¿desaparecio un caso?)"; rc=1; }
exit "$rc"
