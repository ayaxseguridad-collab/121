#!/usr/bin/env bash
# Regresión de la sonda de TypeScript nativo de test-resolucion-clave.sh.
#
# Defecto que cubre: la prueba decidía que su node ejecuta TypeScript nativo con
# `node --experimental-transform-types -e 0`. Un node compilado SIN TypeScript (el paquete `nodejs` de
# Ubuntu 26.04) acepta esa bandera con -e y solo falla al CARGAR un .ts (ERR_NO_TYPESCRIPT): la sonda daba
# un positivo falso y la equivalencia del §5 salía en FAIL. La sonda correcta carga un .ts mínimo.
#
# Se prueba con dos `node` DOBLES delante del PATH, que no dependen de la versión del node real (cualquiera
# con `node -e` sirve, también el 18 de apt de Ubuntu 24.04):
#   · doble «sin TypeScript» (como el de Ubuntu 26.04): con --experimental-transform-types y SIN .ts, QUITA la
#     bandera y delega; con la bandera y un argumento que acaba en .ts imprime ERR_NO_TYPESCRIPT y sale con 1;
#     lo demás lo delega tal cual.
#   · doble «anterior a 22.7» (como el 18 de apt de Ubuntu 24.04): rechaza la bandera con «bad option» y rc 9,
#     y delega lo demás.
# Con cualquiera de los dos, test-resolucion-clave.sh debe dar rc 0, la línea INFO y NI «EQUIV» NI «FAIL
# equivalencia». Un MUTANTE (copia con la sonda vieja `-e 0`) debe salir ROJO con el doble «sin TypeScript»:
# así la regresión demuestra que muerde. (Con el doble «anterior a 22.7» la sonda vieja era correcta, porque ese
# node rechaza la bandera: no hay mutante ahí.)
#
# Sin red, sin credenciales; todo en un directorio temporal propio y con timeout en cada corrida anidada. Sin
# node no hay doble posible: SKIP (nunca verde), con el mismo criterio que test-resolucion-clave.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS="$(cd "$ROOT/.." && pwd)"
PRUEBA="$ROOT/tests/test-resolucion-clave.sh"
T="$(cd "$(mktemp -d)" && pwd -P)"
: "${T:?}"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0; skip=0
TOTAL_ESPERADO=15
TOPE=600   # segundos por corrida anidada de test-resolucion-clave.sh
check() {
  local nombre="$1"; shift
  if [ "$NODE_REAL" = "" ]; then skip=$((skip+1)); echo "SKIP $nombre — node ausente en el PATH"; return 0; fi
  if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $nombre"; fi
}
NODE_REAL="$(command -v node 2>/dev/null || true)"
[ -f "$PRUEBA" ] || { echo "FALTA $PRUEBA"; exit 2; }
[ -d "$SKILLS/talent-issue-craft" ] || { echo "FALTA $SKILLS/talent-issue-craft"; exit 2; }
[ "$NODE_REAL" = "" ] && echo "AVISO: node ausente en el PATH: la regresión no se puede medir (no es verde)"

# ── Los node dobles (la ruta del node real va escrita en cada uno: la prueba los invoca bajo `env -i`) ──
mkdir -p "$T/sin-ts" "$T/viejo"
printf '%s\n' '#!/usr/bin/env bash' \
  'ts=0; flag=0; args=()' \
  'for a in "$@"; do' \
  '  case "$a" in --experimental-transform-types) flag=1; continue ;; *.ts) ts=1 ;; esac' \
  '  args+=("$a")' \
  'done' \
  'if [ "$flag" = 1 ] && [ "$ts" = 1 ]; then' \
  '  echo "Error [ERR_NO_TYPESCRIPT]: Node.js is not compiled with TypeScript support" >&2' \
  '  exit 1' \
  'fi' > "$T/sin-ts/node"
printf '%s\n' '#!/usr/bin/env bash' \
  'for a in "$@"; do' \
  '  if [ "$a" = --experimental-transform-types ]; then' \
  '    echo "$0: bad option: $a" >&2' \
  '    exit 9' \
  '  fi' \
  'done' > "$T/viejo/node"
if [ "$NODE_REAL" != "" ]; then
  printf 'exec %q "${args[@]}"\n' "$NODE_REAL" >> "$T/sin-ts/node"
  printf 'exec %q "$@"\n' "$NODE_REAL" >> "$T/viejo/node"
fi
chmod +x "$T/sin-ts/node" "$T/viejo/node"
printf '%s\n' 'const x: number = 1;' > "$T/sonda.ts"

sin_ts_con_ts() { # el doble sin TypeScript rechaza la carga de un .ts con la bandera
  local salida rc=0
  salida="$(PATH="$T/sin-ts:$PATH" node --experimental-transform-types "$T/sonda.ts" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && case "$salida" in *ERR_NO_TYPESCRIPT*) true ;; *) false ;; esac
}
sin_ts_con_e() { PATH="$T/sin-ts:$PATH" node --experimental-transform-types -e 0 >/dev/null 2>&1; }
viejo_rechaza() { # el doble anterior a 22.7 rechaza la bandera: bad option, rc 9
  local salida rc=0
  salida="$(PATH="$T/viejo:$PATH" node --experimental-transform-types -e 0 2>&1)" || rc=$?
  [ "$rc" = 9 ] && case "$salida" in *"bad option"*) true ;; *) false ;; esac
}
viejo_delega() { PATH="$T/viejo:$PATH" node -e 0 >/dev/null 2>&1; }
check "doble sin TypeScript: cargar un .ts con la bandera → ERR_NO_TYPESCRIPT y rc 1" sin_ts_con_ts
check "doble sin TypeScript: la bandera con -e pasa (rc 0), en cualquier versión del node real" sin_ts_con_e
check "doble anterior a 22.7: la bandera da «bad option» y rc 9" viejo_rechaza
check "doble anterior a 22.7: sin la bandera delega (rc 0)" viejo_delega

# ── Con cada doble: rama INFO, sin equivalencia ─────────────────────────────────────────────────
corre() { # <nombre> <dir-del-doble>: corre la prueba con ese doble delante del PATH; deja <nombre>.out y <nombre>.rc
  local rc=0
  [ "$NODE_REAL" = "" ] || PATH="$2:$PATH" timeout "$TOPE" bash "$PRUEBA" > "$T/$1.out" 2>&1 || rc=$?
  echo "$rc" > "$T/$1.rc"
}
rc_es_0() { [ "$(cat "$T/$1.rc")" = 0 ]; }
tiene_info() { grep -q '^INFO: este node no ejecuta TypeScript nativo' "$T/$1.out"; }
sin_equiv() { ! grep -q 'EQUIV' "$T/$1.out" && ! grep -q 'FAIL equivalencia' "$T/$1.out"; }
total_22() { grep -q '^RESULTADO: PASS=22 FAIL=0 SKIP=0 TOTAL_ESPERADO=22$' "$T/$1.out"; }
for caso in "sin-ts:sin TypeScript" "viejo:anterior a 22.7"; do
  id="${caso%%:*}"; rotulo="${caso#*:}"
  corre "$id" "$T/$id"
  check "con el doble $rotulo: test-resolucion-clave.sh sale con rc 0" rc_es_0 "$id"
  check "con el doble $rotulo: imprime la línea INFO de node sin TypeScript nativo" tiene_info "$id"
  check "con el doble $rotulo: no imprime EQUIV ni FAIL equivalencia" sin_equiv "$id"
  check "con el doble $rotulo: el total sigue en 22 sin FAIL ni SKIP" total_22 "$id"
done

# ── Sin doble: el node real decide (EQUIV si ejecuta TypeScript, INFO si no) ──────────────────────
corre real "$T/no-hay-doble"
real_nativo() { timeout 20 node --experimental-transform-types "$T/sonda.ts" >/dev/null 2>&1; }
sin_doble_resultado() {
  if real_nativo; then
    grep -q '^EQUIV selftest nativo == conductor portable (7 casos «clave:»)$' "$T/real.out" && ! grep -q 'FAIL equivalencia' "$T/real.out"
  else
    grep -q '^INFO: este node no ejecuta TypeScript nativo' "$T/real.out" && ! grep -q 'EQUIV' "$T/real.out"
  fi
}
check "sin doble: test-resolucion-clave.sh sale con rc 0" rc_es_0 real
check "sin doble: EQUIV si este node ejecuta TypeScript; INFO si no" sin_doble_resultado

# ── Mutante: la sonda vieja (-e 0) con el doble sin TypeScript debe dar ROJO ──────────────────────
MUT="$T/mut"
mutante_preparado() {
  mkdir -p "$MUT/skills" || return 1
  cp -a "$ROOT" "$MUT/skills/linear-skill" && cp -a "$SKILLS/talent-issue-craft" "$MUT/skills/talent-issue-craft" || return 1
  local f="$MUT/skills/linear-skill/tests/test-resolucion-clave.sh" orig nuevo
  orig="$(<"$f")"
  nuevo="${orig/'node --experimental-transform-types "$T/sonda.ts"'/'node --experimental-transform-types -e 0'}"
  [ "$nuevo" != "$orig" ] || return 1
  printf '%s\n' "$nuevo" > "$f"
}
mutante_rojo() {
  local rc=0
  mutante_preparado || return 1
  PATH="$T/sin-ts:$PATH" timeout "$TOPE" bash "$MUT/skills/linear-skill/tests/test-resolucion-clave.sh" > "$T/mutante.out" 2>&1 || rc=$?
  [ "$rc" != 0 ] && grep -q 'FAIL equivalencia' "$T/mutante.out"
}
check "mutante (sonda -e 0) con el doble sin TypeScript: sale ROJO con FAIL equivalencia" mutante_rojo

echo "RESULTADO: PASS=$pass FAIL=$fail SKIP=$skip TOTAL_ESPERADO=$TOTAL_ESPERADO"
if [ "$skip" != 0 ]; then
  echo "SKIP=$skip: la regresión NO se ha medido en esta máquina (node ausente en el PATH)"
fi
# SKIP solo puede ser 0 o todos los casos (sin node): cualquier otra omisión es un fallo.
[ "$fail" = 0 ] && [ $((pass + skip)) = "$TOTAL_ESPERADO" ] && { [ "$skip" = 0 ] || [ "$skip" = "$TOTAL_ESPERADO" ]; }
